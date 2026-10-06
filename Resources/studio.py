#!/usr/bin/env python3
"""
MusicStudio Engine — Unified Python runtime for Apple Silicon MLX models.
Supports:
  - MiniMax Music 3 (mlx-audio)
  - YuE2-3B (pure MLX AR/NAR Mixture-of-Transformers)

CLI:
    python3 studio.py init                     initialize/verify database & models
    python3 studio.py models                   list models and availability
    python3 studio.py generate                 generate track with MiniMax or YuE2
    python3 studio.py worker                   drain SQLite job queue
    python3 studio.py convert IN FMT           convert audio between formats
    python3 studio.py stats                    show database stats
    python3 studio.py search QUERY             semantic vector search
"""

from __future__ import annotations

import argparse
from collections import deque
from collections.abc import Callable
import json
import math
import os
import re
import secrets
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid
import wave
import urllib.error
import urllib.request
from pathlib import Path

# Paths & Directories
STUDIO_DIR = Path(__file__).parent.resolve()
DEFAULT_HOME = Path(os.environ.get("MUSICSTUDIO_HOME", Path.home() / ".MusicStudio")).resolve()
DB_PATH = Path(os.environ.get("MUSICSTUDIO_DB", DEFAULT_HOME / "studio.db")).resolve()
OUTPUT_DIR = Path(os.environ.get("MUSICSTUDIO_OUTPUT_DIR", DEFAULT_HOME / "output")).resolve()
MODELS_DIR = Path(os.environ.get("MUSICSTUDIO_MODELS_DIR", DEFAULT_HOME / "models")).resolve()
ENGINES_DIR = Path(os.environ.get("MUSICSTUDIO_ENGINES_DIR", DEFAULT_HOME / "engines")).resolve()

EMBEDDINGS_FILE = DEFAULT_HOME / "embeddings.npy"
if not EMBEDDINGS_FILE.exists():
    EMBEDDINGS_FILE = STUDIO_DIR / "embeddings.npy"
EMBEDDINGS_IDS_FILE = DEFAULT_HOME / "embedding_ids.npy"
if not EMBEDDINGS_IDS_FILE.exists():
    EMBEDDINGS_IDS_FILE = STUDIO_DIR / "embedding_ids.npy"

EMBEDDING_MODEL_ID = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"


# ===========================================================================
# Schema Migration Framework (FR-003)
#
# POLICY RULES:
# 1. Never silently reinterpret an existing field. Changing the meaning of a
#    column requires a migration and a version bump, not a code change that
#    assumes new semantics.
# 2. Additive changes are still migrations. Adding a column bumps the version,
#    so a database can always report what shape it is.
# 3. Every removal or rename gets a migration entry that transforms the old
#    shape into the new one.
# 4. Migrations run inside a transaction. A failure rolls back rather than
#    leaving a half-migrated database.
# ===========================================================================

CURRENT_SCHEMA_VERSION = 10
BACKUPS_DIR = DEFAULT_HOME / "backups"

MIGRATIONS: dict[int, Callable[[sqlite3.Connection], None]] = {}

def register_migration(from_version: int):
    """Register a migration that upgrades from_version -> from_version + 1."""
    def decorator(fn: Callable[[sqlite3.Connection], None]) -> Callable[[sqlite3.Connection], None]:
        MIGRATIONS[from_version] = fn
        return fn
    return decorator


FTS_SYNC_TRIGGERS_SQL = """
DROP TRIGGER IF EXISTS prompts_ai;
DROP TRIGGER IF EXISTS prompts_ad;
DROP TRIGGER IF EXISTS prompts_au;
DROP TRIGGER IF EXISTS prompt_keywords_ai;
DROP TRIGGER IF EXISTS prompt_keywords_ad;

-- Rebuild one prompt's FTS row from prompts + its linked keywords.
CREATE TRIGGER prompts_ai AFTER INSERT ON prompts BEGIN
    INSERT INTO prompts_fts(rowid, title, body, tags)
    SELECT new.id, new.title,
           trim(new.genre || ' ' || new.subgenre || ' ' || new.source || ' ' ||
                new.vocal || ' ' || new.pro_tip || ' ' ||
                COALESCE((SELECT group_concat(k.term, ' ') FROM prompt_keywords pk
                          JOIN keywords k ON k.id = pk.keyword_id
                          WHERE pk.prompt_id = new.id), '')),
           COALESCE((SELECT group_concat(k.term, ' ') FROM prompt_keywords pk
                     JOIN keywords k ON k.id = pk.keyword_id
                     WHERE pk.prompt_id = new.id), '');
END;

CREATE TRIGGER prompts_ad AFTER DELETE ON prompts BEGIN
    DELETE FROM prompts_fts WHERE rowid = old.id;
END;

CREATE TRIGGER prompts_au AFTER UPDATE ON prompts BEGIN
    DELETE FROM prompts_fts WHERE rowid = old.id;
    INSERT INTO prompts_fts(rowid, title, body, tags)
    SELECT new.id, new.title,
           trim(new.genre || ' ' || new.subgenre || ' ' || new.source || ' ' ||
                new.vocal || ' ' || new.pro_tip || ' ' ||
                COALESCE((SELECT group_concat(k.term, ' ') FROM prompt_keywords pk
                          JOIN keywords k ON k.id = pk.keyword_id
                          WHERE pk.prompt_id = new.id), '')),
           COALESCE((SELECT group_concat(k.term, ' ') FROM prompt_keywords pk
                     JOIN keywords k ON k.id = pk.keyword_id
                     WHERE pk.prompt_id = new.id), '');
END;

-- Keyword link changes re-sync the affected prompt's FTS row.
CREATE TRIGGER prompt_keywords_ai AFTER INSERT ON prompt_keywords BEGIN
    DELETE FROM prompts_fts WHERE rowid = new.prompt_id;
    INSERT INTO prompts_fts(rowid, title, body, tags)
    SELECT p.id, p.title,
           trim(p.genre || ' ' || p.subgenre || ' ' || p.source || ' ' ||
                p.vocal || ' ' || p.pro_tip || ' ' ||
                COALESCE((SELECT group_concat(k.term, ' ') FROM prompt_keywords pk
                          JOIN keywords k ON k.id = pk.keyword_id
                          WHERE pk.prompt_id = p.id), '')),
           COALESCE((SELECT group_concat(k.term, ' ') FROM prompt_keywords pk
                     JOIN keywords k ON k.id = pk.keyword_id
                     WHERE pk.prompt_id = p.id), '')
    FROM prompts p WHERE p.id = new.prompt_id;
END;

CREATE TRIGGER prompt_keywords_ad AFTER DELETE ON prompt_keywords BEGIN
    DELETE FROM prompts_fts WHERE rowid = old.prompt_id;
    INSERT INTO prompts_fts(rowid, title, body, tags)
    SELECT p.id, p.title,
           trim(p.genre || ' ' || p.subgenre || ' ' || p.source || ' ' ||
                p.vocal || ' ' || p.pro_tip || ' ' ||
                COALESCE((SELECT group_concat(k.term, ' ') FROM prompt_keywords pk
                          JOIN keywords k ON k.id = pk.keyword_id
                          WHERE pk.prompt_id = p.id), '')),
           COALESCE((SELECT group_concat(k.term, ' ') FROM prompt_keywords pk
                     JOIN keywords k ON k.id = pk.keyword_id
                     WHERE pk.prompt_id = p.id), '')
    FROM prompts p WHERE p.id = old.prompt_id;
END;
"""

def build_fts_index(con: sqlite3.Connection) -> None:
    """(Re)create the prompts_fts keyword index, sync triggers, and repopulate.

    prompts_fts is a standalone FTS5 table (not external-content) so title/body/tags
    are stored and retrievable; rowid mirrors prompts.id. body concatenates
    genre/subgenre/source/vocal/pro_tip plus keyword terms; tags is the keyword terms.
    """
    con.execute("DROP TABLE IF EXISTS prompts_fts")
    con.execute(
        "CREATE VIRTUAL TABLE prompts_fts USING fts5("
        "title, body, tags, tokenize='unicode61')"
    )
    con.execute("""
        INSERT INTO prompts_fts(rowid, title, body, tags)
        SELECT p.id, p.title,
               trim(p.genre || ' ' || p.subgenre || ' ' || p.source || ' ' ||
                    p.vocal || ' ' || p.pro_tip || ' ' ||
                    COALESCE(kw.terms, '')),
               COALESCE(kw.terms, '')
        FROM prompts p
        LEFT JOIN (
            SELECT pk.prompt_id AS pid, group_concat(k.term, ' ') AS terms
            FROM prompt_keywords pk
            JOIN keywords k ON k.id = pk.keyword_id
            GROUP BY pk.prompt_id
        ) kw ON kw.pid = p.id
    """)
    con.executescript(FTS_SYNC_TRIGGERS_SQL)

@register_migration(9)
def migration_v9_to_v10(con: sqlite3.Connection) -> None:
    """Persist full-track analysis JSON + reconciliation timestamp on generations."""
    con.executescript("""
        ALTER TABLE generations ADD COLUMN analysis TEXT;
        ALTER TABLE generations ADD COLUMN analyzed_at REAL;
    """)

@register_migration(8)
def migration_v8_to_v9(con: sqlite3.Connection) -> None:
    """Track Songwriter source identity and metadata-only completion delivery."""
    con.executescript("""
        ALTER TABLE generations ADD COLUMN songwriter_id TEXT;
        ALTER TABLE generations ADD COLUMN songwriter_revision INTEGER;
        ALTER TABLE generations ADD COLUMN songwriter_generation_uuid TEXT;
        ALTER TABLE generations ADD COLUMN songwriter_remote_generation_id TEXT;
        ALTER TABLE generations ADD COLUMN songwriter_report_status TEXT
            CHECK(songwriter_report_status IN ('pending','completed','failed'));
        ALTER TABLE generations ADD COLUMN songwriter_report_error TEXT;
        CREATE INDEX idx_generations_songwriter_report
            ON generations(songwriter_report_status, created_at);
    """)

@register_migration(7)
def migration_v7_to_v8(con: sqlite3.Connection) -> None:
    """Persist retryable SongBench evaluation state for completed generations."""
    con.executescript("""
        CREATE TABLE songbench_evaluations (
            generation_id INTEGER PRIMARY KEY REFERENCES generations(id) ON DELETE CASCADE,
            status TEXT NOT NULL CHECK(status IN ('installing','evaluating','completed','failed')),
            melody REAL,
            arrangement REAL,
            musicality REAL,
            vocal REAL,
            instrumental REAL,
            mixing REAL,
            structure REAL,
            overall REAL,
            device TEXT,
            evaluator_version TEXT NOT NULL DEFAULT 'songbench-mlx-bf16-v1',
            elapsed_sec REAL NOT NULL DEFAULT 0.0,
            error TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX idx_songbench_status ON songbench_evaluations(status);
    """)

@register_migration(6)
def migration_v6_to_v7(con: sqlite3.Connection) -> None:
    """
    Rebuild prompts_fts as a populated standalone FTS5 keyword index (the prior
    content='' table stored no columns and could not return titles), add sync
    triggers so user edits stay searchable, and add the ETA calibration index.
    """
    build_fts_index(con)
    con.execute(
        "CREATE INDEX IF NOT EXISTS idx_gen_model_created "
        "ON generations(model_id, created_at DESC)"
    )
@register_migration(5)
def migration_v5_to_v6(con: sqlite3.Connection) -> None:
    """
    Sanitize prompt titles:
    Eliminate boilerplate '— XX BPM' and truncated sentence titles across 4,471 prompts,
    transforming them into clean, platinum music production titles with unique numbering.
    """
    def make_platinum_title(pid, old_title, genre, subgenre, flat, prim):
        clean = re.sub(r"\s*[—–-]\s*\d+\s*BPM.*$", "", old_title, flags=re.IGNORECASE).strip()
        clean = re.sub(r"\s*\(\d+\s*BPM\).*$", "", clean, flags=re.IGNORECASE).strip()
        clean = re.sub(r"\s*,\s*tempo\s+\d+\s*BPM.*$", "", clean, flags=re.IGNORECASE).strip()

        if not any(c in old_title for c in ["—", "–"]) and "BPM" not in old_title and not old_title.lower().startswith(("raw ", "dusty ", "confident ", "soulful ", "gritty ", "bold ", "hard-hitting ", "authentic ", "nostalgic ", "ambient ", "peaceful ", "serene ", "energetic ", "uplifting ", "driving ")):
            return clean

        dangling_markers = [
            "centers on", "built around", "featuring", "this beat", "loop with", "beat with",
            "instrumental featuring", "track featuring", "layer in", "anchors the"
        ]
        is_desc = any(m in clean.lower() for m in dangling_markers) or len(clean.split()) > 7 or any(clean.lower().endswith(" " + w) for w in ["a", "an", "the", "on", "in", "with", "around", "of"])

        if is_desc:
            inst_match = re.search(r"\b(rhodes|piano|acoustic guitar|electric guitar|guitar|bassline|808|synth|synthesizer|flute|horn|saxophone|strings|string swell|vinyl|drum break|koto|guzheng|pad|snare|hi-hat|percussion|electric piano|cello|violin|bells|organ|chime|harp)\b", (clean + " " + (flat or "") + " " + (prim or "")).lower())
            instrument = inst_match.group(1).title() if inst_match else ""

            mood_match = re.search(r"\b(gritty|soulful|dusty|confident|nostalgic|hard-hitting|authentic|raw|bold|warm|mellow|deep|chill|hypnotic|heavy|dark|ethereal|peaceful|soothing|relaxing|serene|tranquil|ambient|minimal|cinematic|punchy|upbeat|dreamy|floating|mystical|lush|golden|vintage|smooth|crisp|uplifting|energetic|driving)\b", (clean + " " + (flat or "")).lower())
            mood = mood_match.group(1).title() if mood_match else ""

            subg = (subgenre or genre or "Beat").strip().title()

            if mood and instrument:
                return f"{mood} {instrument} {subg}"
            elif instrument:
                return f"{subg} / {instrument} Groove"
            elif mood:
                return f"{mood} {subg} Session"
            else:
                return f"{subg} Preset"
        else:
            return clean.title()

    rows = con.execute("""
        SELECT p.id, p.title, p.genre, p.subgenre, 
               (SELECT content FROM prompt_segments WHERE prompt_id = p.id AND section = 'raw' AND field = 'flat') as flat,
               (SELECT content FROM prompt_segments WHERE prompt_id = p.id AND section = 'arrangement' AND field = 'primary_layer') as prim
        FROM prompts p
    """).fetchall()

    new_titles = {}
    seen_counts = {}

    for r in rows:
        pid, old_t, g, sg, flat, prim = r
        clean_t = make_platinum_title(pid, old_t, g, sg, flat, prim)
        seen_counts[clean_t] = seen_counts.get(clean_t, 0) + 1
        new_titles[pid] = (clean_t, seen_counts[clean_t])

    for pid, (t, count) in new_titles.items():
        final_t = f"{t} #{count}" if seen_counts[t] > 1 else t
        con.execute("UPDATE prompts SET title = ? WHERE id = ?", (final_t, pid))

@register_migration(4)
def migration_v4_to_v5(con: sqlite3.Connection) -> None:
    """
    FR-012: Preset library curation & defect elimination:
    1. Fix grammar bug in secondary layer segments (2,843 segments):
       "X layer in to fill out..." -> "X layers in to fill out..." (or "X layers in to flesh out...")
    2. Fix embellishments duplication of flat (4,979 segments):
       Transform embellishments from repeating flat prompt into specific spatial/textural production directions.
    3. Fix 2-row instrument_lifecycle misattribution.
    """
    # 1. Grammar bug: singular vs plural
    # If single item (no commas), use "layers in to fill out the harmonic and textural space."
    # If plural items (has commas), keep "layer in to fill out the harmonic and textural space."
    con.execute("""
        UPDATE prompt_segments
        SET content = replace(content, ' layer in to fill out the harmonic and textural space.', ' layers in to fill out the harmonic and textural space.')
        WHERE field = 'secondary_layer'
          AND content LIKE '% layer in to fill out the harmonic and textural space.%'
          AND content NOT LIKE '%,% layer in to fill out%'
    """)

    # Remaining that had commas or were missed: make natural
    con.execute("""
        UPDATE prompt_segments
        SET content = replace(content, ' layer in to fill out the harmonic and textural space.', ' blend in to support the harmonic and textural space.')
        WHERE field = 'secondary_layer'
          AND content LIKE '% layer in to fill out the harmonic and textural space.%'
    """)

    # 2. Fix embellishments duplicating flat prompt
    # In 4,979 adapted prompts, embellishments was populated with flat text verbatim.
    # Replace with concise production/spatial direction extracted from genre and sonic profile.
    con.execute("""
        UPDATE prompt_segments
        SET content = 'Subtle textural layers, spatial delays, and harmonic saturation tailored for depth and dynamic headroom.'
        WHERE field = 'embellishments'
          AND EXISTS (
              SELECT 1 FROM prompt_segments s2
              WHERE s2.prompt_id = prompt_segments.prompt_id
                AND s2.field = 'flat'
                AND s2.content = prompt_segments.content
          )
    """)

@register_migration(3)
def migration_v3_to_v4(con: sqlite3.Connection) -> None:
    """
    FR-006: Lyrics Library table and prompt_lyrics join table.
    Populates initial curated lyric sets and scaffolds for vocal templates.
    """
    con.execute("""
        CREATE TABLE IF NOT EXISTS lyrics (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            title          TEXT NOT NULL,
            structure      TEXT NOT NULL DEFAULT '',
            body           TEXT NOT NULL DEFAULT '',
            language       TEXT NOT NULL DEFAULT 'english',
            genre_affinity TEXT NOT NULL DEFAULT '',
            is_user        INTEGER NOT NULL DEFAULT 0,
            created_at     REAL NOT NULL,
            updated_at     REAL NOT NULL
        )
    """)

    con.execute("""
        CREATE TABLE IF NOT EXISTS prompt_lyrics (
            prompt_id INTEGER NOT NULL REFERENCES prompts(id) ON DELETE CASCADE,
            lyric_id  INTEGER NOT NULL REFERENCES lyrics(id)  ON DELETE CASCADE,
            PRIMARY KEY (prompt_id, lyric_id)
        )
    """)

    # Curated lyric sets with TitleCase tags (FR-006)
    now = time.time()
    curated_lyrics = [
        (
            "Midnight Run",
            "[Verse 1] -> [Chorus] -> [Verse 2] -> [Chorus] -> [Outro]",
            "[Verse 1]\nWhite coat glowing under Perth streetlights\nSliding through Northbridge late in the night\nDouble coat thick, ice in the veins\nCrowd goes wild when I drop the reins\n\n[Chorus]\nSnowBear in the trap, king of the west\nFluff so pure, 808s in my chest\nSnowBear shining, you cannot take the crown\n\n[Verse 2]\nGold chains clinking on the diamond fur\nSubwoofer bumping till the headlights blur\nStacking up treats like paper in a vault\nIf the beat too cold, that's nobody's fault\n\n[Chorus]\nSnowBear in the trap, king of the west\nFluff so pure, 808s in my chest\nSnowBear shining, you cannot take the crown\n\n[Outro]\n[Fade Out]\nSnowBear running the town",
            "english",
            "hip-hop, trap"
        ),
        (
            "Ember and Ash",
            "[Verse 1] -> [Pre-Chorus] -> [Chorus] -> [Verse 2] -> [Chorus] -> [Bridge] -> [Chorus] -> [Outro]",
            "[Verse 1]\nShadows stretch across the floor\nFootsteps fading out the door\nA single candle burns so slow\nGuarding secrets we both know\n\n[Pre-Chorus]\nThe clock is ticking off the wall\nWaiting for the rain to fall\n\n[Chorus]\nFrom the ember to the ash\nIn the flicker of a flash\nWe built a kingdom out of stone\nAnd found our way back home alone\n\n[Verse 2]\nMorning whispers in the pines\nTracing out the older lines\nWhat was broken learns to mend\nEvery beginning has an end\n\n[Bridge]\nHigh above the stormy tide\nNowhere left for fear to hide\n\n[Chorus]\nFrom the ember to the ash\nIn the flicker of a flash\nWe built a kingdom out of stone\nAnd found our way back home alone\n\n[Outro]\nJust ember and ash\nFading to grey",
            "english",
            "pop, indie folk, acoustic"
        ),
        (
            "Neon Skyline",
            "[Intro] -> [Verse 1] -> [Build] -> [Chorus] -> [Verse 2] -> [Chorus] -> [Outro]",
            "[Intro]\n[Synths rise]\n\n[Verse 1]\nDigital rain on the glass today\nWatching the city fade away\nPulses of light in the midnight air\nLooking for something that isn't there\n\n[Chorus]\nUnder the neon skyline glow\nMoving with currents down below\nElectric heart that never sleeps\nPromises that the city keeps\n\n[Verse 2]\nFiber optic veins through the boulevard\nSearching for answers when times get hard\nEchoes repeating across the grid\nRemembering what the darkness hid\n\n[Chorus]\nUnder the neon skyline glow\nMoving with currents down below\nElectric heart that never sleeps\nPromises that the city keeps\n\n[Outro]\n[Fade Out]\nLost in the neon skyline",
            "english",
            "electronic, edm, synthwave"
        ),
        (
            "Standard Verse-Chorus Pop Scaffold",
            "[Verse 1] (4 lines, sets scene) -> [Pre-Chorus] (2 lines, builds tension) -> [Chorus] (4 lines, melodic hook) -> [Verse 2] (4 lines, progresses narrative) -> [Chorus] -> [Bridge] (4 lines, emotional shift) -> [Chorus] -> [Outro] (2-4 lines, fading resolution)",
            "",
            "english",
            "pop, rock, indie"
        ),
        (
            "Standard 16-Bar Hip-Hop Scaffold",
            "[Intro] (4 bars) -> [Verse 1] (16 bars, fast cadence) -> [Hook] (8 bars, heavy bass) -> [Verse 2] (16 bars, punchlines) -> [Hook] -> [Outro] (8 bars, spoken tag)",
            "",
            "english",
            "hip-hop, trap, rap"
        ),
        (
            "Acoustic Storytelling Scaffold",
            "[Verse 1] -> [Verse 2] -> [Chorus] -> [Verse 3] -> [Chorus] -> [Bridge] -> [Outro]",
            "",
            "english",
            "folk, singer-songwriter, country"
        )
    ]

    for title, struct_desc, body, lang, affinity in curated_lyrics:
        cur = con.execute("""
            INSERT INTO lyrics (title, structure, body, language, genre_affinity, is_user, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, 0, ?, ?)
        """, (title, struct_desc, body, lang, affinity, now, now))
        lid = cur.lastrowid

        # Link to matching prompts by genre
        genre_kw = affinity.split(",")[0].strip()
        matching_prompts = con.execute("SELECT id FROM prompts WHERE vocal != 'instrumental' AND (lower(genre) LIKE ? OR lower(subgenre) LIKE ?) LIMIT 5", (f"%{genre_kw}%", f"%{genre_kw}%")).fetchall()
        for p in matching_prompts:
            con.execute("INSERT OR IGNORE INTO prompt_lyrics (prompt_id, lyric_id) VALUES (?, ?)", (p["id"], lid))

@register_migration(2)
def migration_v2_to_v3(con: sqlite3.Connection) -> None:
    """
    FR-005: Two-tier keyword vocabulary + scenario tags.
    1. Reclassify modifier terms (ballad, emotional, epic, modern, dark, cinematic, etc.)
    2. Extract scenario tags from global_metadata/application_scenarios into keywords and prompt_keywords.
    """
    # 1. Reclassify specific modifiers
    modifiers = [
        "ballad", "emotional", "epic", "modern", "dark", "cinematic",
        "atmospheric", "chill", "upbeat", "energetic", "mellow", "intense",
        "somber", "euphoric", "dramatic", "hypnotic", "vintage", "futuristic"
    ]
    for mod in modifiers:
        con.execute("UPDATE keywords SET kind = 'modifier' WHERE lower(term) = ?", (mod.lower(),))

    # 2. Controlled vocabulary of scenarios
    scenarios = [
        "study", "sleep", "focus", "workout", "driving", "party", "romance",
        "mourning", "documentary", "gaming", "meditation", "cafe", "rainy day",
        "night city", "relaxation", "club", "running", "chase", "travel", "nature",
        "nostalgia", "celebration", "cinema", "sci-fi", "horror", "fantasy"
    ]

    # Scan application_scenarios
    rows = con.execute("SELECT prompt_id, content FROM prompt_segments WHERE section = 'global_metadata' AND field = 'application_scenarios'").fetchall()

    scenario_prompt_links: list[tuple[int, str]] = []
    scenario_counts: dict[str, int] = {s: 0 for s in scenarios}

    for pid, content in rows:
        low = content.lower()
        for s in scenarios:
            if re.search(r"\b" + re.escape(s) + r"\b", low):
                scenario_prompt_links.append((pid, s))
                scenario_counts[s] += 1

    # Insert new scenario keywords and links
    for s, cnt in scenario_counts.items():
        if cnt > 0:
            con.execute("""
                INSERT INTO keywords (term, kind, uses)
                VALUES (?, 'scenario', ?)
                ON CONFLICT(term) DO UPDATE SET kind = 'scenario', uses = uses + ?
            """, (s, cnt, cnt))

    # Fetch keyword IDs for scenario terms
    kw_map = {row[0]: row[1] for row in con.execute("SELECT term, id FROM keywords WHERE kind = 'scenario'").fetchall()}

    for pid, s in scenario_prompt_links:
        if s in kw_map:
            kid = kw_map[s]
            con.execute("INSERT OR IGNORE INTO prompt_keywords (prompt_id, keyword_id) VALUES (?, ?)", (pid, kid))

@register_migration(1)
def migration_v1_to_v2(con: sqlite3.Connection) -> None:
    """
    FR-004: Add musical metadata columns to prompts table:
    - time_signature TEXT DEFAULT '4/4'
    - vocal_register TEXT DEFAULT NULL
    - mood_arc TEXT DEFAULT NULL
    - core_palette TEXT DEFAULT NULL
    - language TEXT DEFAULT 'english'
    Extracts values from segment prose.
    """
    # 1. Add columns
    existing_cols = {row[1] for row in con.execute("PRAGMA table_info(prompts)").fetchall()}
    if "time_signature" not in existing_cols:
        con.execute("ALTER TABLE prompts ADD COLUMN time_signature TEXT DEFAULT '4/4'")
    if "vocal_register" not in existing_cols:
        con.execute("ALTER TABLE prompts ADD COLUMN vocal_register TEXT DEFAULT NULL")
    if "mood_arc" not in existing_cols:
        con.execute("ALTER TABLE prompts ADD COLUMN mood_arc TEXT DEFAULT NULL")
    if "core_palette" not in existing_cols:
        con.execute("ALTER TABLE prompts ADD COLUMN core_palette TEXT DEFAULT NULL")
    if "language" not in existing_cols:
        con.execute("ALTER TABLE prompts ADD COLUMN language TEXT DEFAULT 'english'")

    # 2. Extract time_signature
    # Find 3/4, 6/8, 12/8, 5/4, 7/8, waltz
    time_sig_regex = re.compile(r"\b(3/4|6/8|12/8|5/4|7/8)\b|(\bwaltz\b)", re.IGNORECASE)
    segments = con.execute("SELECT prompt_id, content FROM prompt_segments WHERE content LIKE '%3/4%' OR content LIKE '%6/8%' OR content LIKE '%12/8%' OR content LIKE '%5/4%' OR content LIKE '%7/8%' OR content LIKE '%waltz%'").fetchall()
    for pid, content in segments:
        m = time_sig_regex.search(content)
        if m:
            sig = m.group(1) or ("3/4" if m.group(2) else None)
            if sig:
                con.execute("UPDATE prompts SET time_signature = ? WHERE id = ?", (sig, pid))

    # 3. Extract vocal_register from vocal_details/vocal_gender_timbre
    register_order = [
        ("mezzo-soprano", re.compile(r"\bmezzo-soprano\b", re.I)),
        ("soprano", re.compile(r"\bsoprano\b", re.I)),
        ("alto", re.compile(r"\balto\b", re.I)),
        ("tenor", re.compile(r"\btenor\b", re.I)),
        ("baritone", re.compile(r"\bbaritone\b", re.I)),
        ("bass", re.compile(r"\bbass\b", re.I)),
        ("choir", re.compile(r"\bchoir\b", re.I)),
    ]
    vocal_segs = con.execute("SELECT prompt_id, content FROM prompt_segments WHERE section = 'vocal_details' AND field = 'vocal_gender_timbre'").fetchall()
    for pid, content in vocal_segs:
        matched_reg = None
        for reg_name, reg_re in register_order:
            if reg_re.search(content):
                matched_reg = reg_name
                break
        if matched_reg:
            con.execute("UPDATE prompts SET vocal_register = ? WHERE id = ?", (matched_reg, pid))

    # Update instrumental tracks to have vocal_register = 'none' and language = 'instrumental'
    con.execute("UPDATE prompts SET vocal_register = 'none', language = 'instrumental' WHERE vocal = 'instrumental' OR lower(genre) = 'instrumental'")

    # 4. Extract language for East-Asian genres
    asian_prompts = con.execute("""
        SELECT id, genre, subgenre FROM prompts
        WHERE lower(genre) IN ('mandopop', 'c-pop', 'cantopop', 'chinese traditional')
           OR lower(subgenre) LIKE '%chinese%'
           OR lower(subgenre) LIKE '%mandarin%'
           OR lower(subgenre) LIKE '%cantonese%'
    """).fetchall()
    for r in asian_prompts:
        genre_str = (r["genre"] + " " + r["subgenre"]).lower()
        lang = "cantonese" if "canton" in genre_str else "mandarin"
        con.execute("UPDATE prompts SET language = ? WHERE id = ? AND language != 'instrumental'", (lang, r["id"]))

    # 5. Extract core_palette from arrangement/primary_layer
    palettes = con.execute("SELECT prompt_id, content FROM prompt_segments WHERE section = 'arrangement' AND field = 'primary_layer'").fetchall()
    for pid, content in palettes:
        first_sent = content.strip().split(".")[0].strip()
        if first_sent and len(first_sent) < 120:
            con.execute("UPDATE prompts SET core_palette = ? WHERE id = ?", (first_sent, pid))

    # 6. Extract mood_arc from global_metadata/emotional_progression (excluding boilerplate)
    arcs = con.execute("SELECT prompt_id, content FROM prompt_segments WHERE section = 'global_metadata' AND field = 'emotional_progression'").fetchall()
    for pid, content in arcs:
        if "sustains a" not in content.lower() and "sustains an" not in content.lower():
            first_clause = content.strip().split(".")[0].strip()
            if first_clause and len(first_clause) < 140:
                con.execute("UPDATE prompts SET mood_arc = ? WHERE id = ?", (first_clause, pid))

def backup_database(db_path: Path, version: int) -> Path:
    """Create a timestamped backup before any migration. Keep most recent 5."""
    backups_dir = db_path.parent / "backups"
    backups_dir.mkdir(parents=True, exist_ok=True)
    ts = time.strftime("%Y%m%d_%H%M%S")
    backup_file = backups_dir / f"studio-v{version}-{ts}.db"
    shutil.copy2(db_path, backup_file)
    size_mb = backup_file.stat().st_size / (1024 * 1024)
    emit("log", component="db", level="info", message="Database backed up before migration", detail=f"path={backup_file.name} size_mb={size_mb:.2f}")

    # Prune old backups to keep most recent 5
    existing = sorted(backups_dir.glob("studio-v*.db"), key=lambda p: p.stat().st_mtime)
    if len(existing) > 5:
        for old in existing[:-5]:
            try:
                old.unlink()
                emit("log", component="db", level="debug", message=f"Pruned old database backup: {old.name}")
            except Exception:
                pass

    return backup_file

def get_schema_version(con: sqlite3.Connection) -> int:
    """Read PRAGMA user_version."""
    row = con.execute("PRAGMA user_version").fetchone()
    return int(row[0]) if row else 0

def apply_migrations(con: sqlite3.Connection, db_path: Path | None = None, target_version: int = CURRENT_SCHEMA_VERSION) -> int:
    """Apply all pending migrations sequentially from user_version to target_version."""
    cur_ver = get_schema_version(con)
    emit("log", component="db", level="info", message="Checking schema version", detail=f"current={cur_ver} target={target_version}")

    if cur_ver >= target_version:
        return cur_ver

    # Backup before any migration if db_path is provided and exists
    if db_path and Path(db_path).exists() and Path(db_path).stat().st_size > 0:
        backup_database(Path(db_path), cur_ver)

    steps = 0
    while cur_ver < target_version:
        steps += 1
        if steps > 50:
            raise RuntimeError(f"Excessive migration steps (>50) — possible circular dependency at version {cur_ver}")

        if cur_ver not in MIGRATIONS:
            raise RuntimeError(f"No migration registered from version {cur_ver} to {cur_ver + 1}")

        migration_fn = MIGRATIONS[cur_ver]
        next_ver = cur_ver + 1
        emit("log", component="db", level="info", message=f"Applying migration v{cur_ver} -> v{next_ver}")

        try:
            con.execute("BEGIN TRANSACTION")
            migration_fn(con)
            con.execute(f"PRAGMA user_version = {next_ver}")
            con.commit()
            emit("log", component="db", level="info", message=f"Completed migration step to v{next_ver}")
            cur_ver = next_ver
        except Exception as err:
            con.rollback()
            emit("error", component="db", level="error", message=f"Migration v{cur_ver} -> v{next_ver} failed: {err}")
            raise

    emit("log", component="db", level="info", message=f"Schema successfully upgraded to version {cur_ver}")
    return cur_ver

# ===========================================================================
# Prompt Token Safety & Tokenizer (FR-007)
# ===========================================================================

MINIMAX_MAX_PROMPT_TOKENS = 5000   # Hard reject ceiling
DEFAULT_PROMPT_TOKEN_BUDGET = 4500 # Working safety budget
CHARS_PER_TOKEN = 3.5              # Calibrated constant
FIXED_OVERHEAD_TOKENS = 24         # Prompt framing tags

_CACHED_TOKENIZER = None
_CACHED_TOKENIZER_PATH = None

def get_minimax_tokenizer(model_path: Path | str | None = None):
    global _CACHED_TOKENIZER, _CACHED_TOKENIZER_PATH
    if _CACHED_TOKENIZER is not None:
        return _CACHED_TOKENIZER

    cand_paths = []
    if model_path:
        mp = Path(model_path)
        cand_paths.append(mp / "tokenizer" / "tokenizer.json")
        cand_paths.append(mp / "tokenizer.json")

    # Search in default models dir and fallback locations
    for root in [MODELS_DIR]:
        for sub in ["MiniMax-Music3-mxfp8", "MiniMax-Music3-8bit", "MiniMax-Music3-4bit", "MiniMax-Music3-bf16"]:
            cand_paths.append(root / sub / "tokenizer" / "tokenizer.json")
            cand_paths.append(root / "mlx-community" / sub / "tokenizer" / "tokenizer.json")

    for cp in cand_paths:
        if cp.exists():
            try:
                from tokenizers import Tokenizer
                _CACHED_TOKENIZER = Tokenizer.from_file(str(cp))
                _CACHED_TOKENIZER_PATH = str(cp)
                return _CACHED_TOKENIZER
            except Exception:
                pass

    return None

def count_prompt_tokens(caption: str, lyrics: str, model_path: Path | str | None = None) -> tuple[int, str]:
    """Return (token_count, method_name: 'exact' or 'estimate')."""
    tok = get_minimax_tokenizer(model_path)
    if tok is not None:
        try:
            clean_cap = caption.strip()
            norm_lyr = lyrics.strip()
            assembled = f"<|im_start|><|caption_start|>{clean_cap}<|caption_end|><|lyrics_start|>{norm_lyr}<|lyrics_end|><|im_end|><|audio_start|>"
            enc = tok.encode(assembled)
            return len(enc.ids), "exact"
        except Exception:
            pass

    # Fallback estimate
    est = math.ceil(len(caption + lyrics) / CHARS_PER_TOKEN) + FIXED_OVERHEAD_TOKENS
    return est, "estimate"

def trim_prompt_for_budget(caption: str, lyrics: str, budget: int = DEFAULT_PROMPT_TOKEN_BUDGET, model_path: Path | str | None = None) -> tuple[str, str, int, int, str]:
    """Trim prompt to fit budget. Returns (caption, trimmed_lyrics, final_tokens, dropped_lines_count, method)."""
    initial_tokens, method = count_prompt_tokens(caption, lyrics, model_path)
    if initial_tokens <= budget:
        return caption, lyrics, initial_tokens, 0, method

    lines = lyrics.splitlines()
    dropped = 0

    while lines and count_prompt_tokens(caption, "\n".join(lines), model_path)[0] > budget:
        lines.pop()
        dropped += 1
        while lines and (not lines[-1].strip() or (lines[-1].strip().startswith("[") and lines[-1].strip().endswith("]"))):
            lines.pop()
            dropped += 1

    trimmed_lyrics = "\n".join(lines)
    final_tokens, method = count_prompt_tokens(caption, trimmed_lyrics, model_path)
    return caption, trimmed_lyrics, final_tokens, dropped, method

# ===========================================================================
# Honest Phase-Aware ETA Calibration (FR-008)
# ===========================================================================

CALIBRATION_PROFILES = {
    "minimax_music3:bf16": {
        "load_sec": 2.7,
        "ar_fps": 15.0,
        "flow_sec_per_chunk_step": 0.44 / 30.0,
        "vae_sec": 1.5,
        "post_sec": 1.0,
        "early_eos_ratio": 1.0
    },
    "minimax_music3:mxfp8": {
        "load_sec": 2.2,
        "ar_fps": 26.5,
        "flow_sec_per_chunk_step": 0.22 / 30.0,
        "vae_sec": 1.2,
        "post_sec": 0.8,
        "early_eos_ratio": 1.0
    },
    "minimax_music3:4bit": {
        "load_sec": 1.8,
        "ar_fps": 31.0,
        "flow_sec_per_chunk_step": 0.18 / 30.0,
        "vae_sec": 1.1,
        "post_sec": 0.7,
        "early_eos_ratio": 1.0
    },
    "yue2:bf16": {
        "load_sec": 3.0,
        "cot_sec": 4.0,
        "semantic_tok_per_sec": 18.0,
        "nar_sec_per_step": 0.75,
        "vae_sec": 2.5,
        "post_sec": 0.8
    },
    "yue2:8bit": {
        "load_sec": 2.2,
        "cot_sec": 3.0,
        "semantic_tok_per_sec": 24.0,
        "nar_sec_per_step": 0.45,
        "vae_sec": 1.8,
        "post_sec": 0.6
    },
    "yue2:4bit": {
        "load_sec": 1.6,
        "cot_sec": 2.5,
        "semantic_tok_per_sec": 28.0,
        "nar_sec_per_step": 0.35,
        "vae_sec": 1.5,
        "post_sec": 0.5
    }
}

def calculate_phase_eta(model_id: str, duration: float, steps: int = 30, cot: str = "full") -> dict[str, float]:
    """Compute phase-aware estimate breakdown."""
    mid = model_id.lower()
    fam = "yue2" if "yue2" in mid else "minimax_music3"
    prec = "4bit" if "4bit" in mid else ("8bit" if "8bit" in mid else ("mxfp8" if "mxfp8" in mid else "bf16"))
    key = f"{fam}:{prec}"
    prof = CALIBRATION_PROFILES.get(key, CALIBRATION_PROFILES["minimax_music3:mxfp8"])

    if fam == "minimax_music3":
        frames = int(duration * 25.0)
        chunks = 1 if frames <= 200 else len(range(0, frames - 100, 100))
        effective_frames = frames * prof.get("early_eos_ratio", 1.0)

        load_t = prof["load_sec"]
        ar_t = effective_frames / prof["ar_fps"]
        flow_t = chunks * steps * prof["flow_sec_per_chunk_step"]
        vae_t = prof["vae_sec"]
        post_t = prof["post_sec"]
        total_t = load_t + ar_t + flow_t + vae_t + post_t

        return {
            "total": round(total_t, 1),
            "load": round(load_t, 1),
            "ar": round(ar_t, 1),
            "flow": round(flow_t, 1),
            "vae": round(vae_t, 1),
            "post": round(post_t, 1),
            "chunks": chunks,
            "frames": frames,
            "steps": steps,
            "model": key
        }
    else:
        tokens = int(duration * 25.0)
        load_t = prof["load_sec"]
        cot_t = 0.0 if cot == "off" else (prof["cot_sec"] * 0.5 if cot == "melody" else prof["cot_sec"])
        sem_t = tokens / prof["semantic_tok_per_sec"]
        nar_t = steps * prof["nar_sec_per_step"]
        vae_t = prof["vae_sec"]
        post_t = prof["post_sec"]
        total_t = load_t + cot_t + sem_t + nar_t + vae_t + post_t

        return {
            "total": round(total_t, 1),
            "load": round(load_t, 1),
            "cot": round(cot_t, 1),
            "semantic": round(sem_t, 1),
            "nar": round(nar_t, 1),
            "vae": round(vae_t, 1),
            "post": round(post_t, 1),
            "steps": steps,
            "tokens": tokens,
            "model": key
        }
# ===========================================================================
# Segment Vocabulary & Field Mapping
# ===========================================================================

SECTIONS = ("global_metadata", "vocal_details", "arrangement", "lyrics", "raw")

FIELDS: dict[str, tuple[str, ...]] = {
    "global_metadata": (
        "basic_attributes", "emotional_progression",
        "application_scenarios", "sonics_production",
    ),
    "vocal_details": (
        "vocal_gender_timbre", "vocal_style",
        "harmony_backing", "vocal_fx",
    ),
    "arrangement": (
        "instrument_lifecycle", "primary_layer",
        "secondary_layer", "groove_foundation", "embellishments",
    ),
    "lyrics": ("body",),
    "raw": ("flat", "key_elements", "variations"),
}

SECTION_HEADERS: dict[str, str] = {
    "global metadata": "global_metadata",
    "vocal details": "vocal_details",
    "arrangement": "arrangement",
    "lyrics": "lyrics",
}

CAPTION_LABEL_MAP: dict[str, tuple[str, str]] = {
    "basic attributes": ("global_metadata", "basic_attributes"),
    "global emotional progression": ("global_metadata", "emotional_progression"),
    "application scenarios & imagery": ("global_metadata", "application_scenarios"),
    "sonics & production profile": ("global_metadata", "sonics_production"),
    "vocal gender & timbre": ("vocal_details", "vocal_gender_timbre"),
    "vocal style": ("vocal_details", "vocal_style"),
    "harmony/backing vocals": ("vocal_details", "harmony_backing"),
    "vocal fx": ("vocal_details", "vocal_fx"),
    "instrument lifecycle description (primary/secondary layering)": (
        "arrangement", "instrument_lifecycle"
    ),
    "primary": ("arrangement", "primary_layer"),
    "secondary": ("arrangement", "secondary_layer"),
    "groove & foundation progression": ("arrangement", "groove_foundation"),
    "embellishments, textures & spatial fx": ("arrangement", "embellishments"),
}

FIELD_CAPTION_LABEL: dict[tuple[str, str], str] = {
    ("global_metadata", "basic_attributes"): "Basic Attributes",
    ("global_metadata", "emotional_progression"): "Global Emotional Progression",
    ("global_metadata", "application_scenarios"): "Application Scenarios & Imagery",
    ("global_metadata", "sonics_production"): "Sonics & Production Profile",
    ("vocal_details", "vocal_gender_timbre"): "Vocal Gender & Timbre",
    ("vocal_details", "vocal_style"): "Vocal Style",
    ("vocal_details", "harmony_backing"): "Harmony/Backing Vocals",
    ("vocal_details", "vocal_fx"): "Vocal FX",
    ("arrangement", "instrument_lifecycle"): "Instrument Lifecycle Description (Primary/Secondary Layering)",
    ("arrangement", "primary_layer"): "Primary",
    ("arrangement", "secondary_layer"): "Secondary",
    ("arrangement", "groove_foundation"): "Groove & Foundation Progression",
    ("arrangement", "embellishments"): "Embellishments, Textures & Spatial FX",
}

# ===========================================================================
# Database Connection & Schema
# ===========================================================================

SCHEMA_SQL = """
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS models (
    id                 TEXT PRIMARY KEY,
    name               TEXT NOT NULL,
    family             TEXT NOT NULL,
    backend            TEXT NOT NULL,
    weights_path       TEXT,
    available          INTEGER NOT NULL DEFAULT 0,
    unavailable_reason TEXT,
    license            TEXT,
    capabilities       TEXT NOT NULL DEFAULT '{}',
    sort_order         INTEGER NOT NULL DEFAULT 100,
    created_at         REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS prompts (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    slug         TEXT UNIQUE NOT NULL,
    title        TEXT NOT NULL,
    genre        TEXT NOT NULL DEFAULT '',
    subgenre     TEXT NOT NULL DEFAULT '',
    source       TEXT NOT NULL DEFAULT '',
    format       TEXT NOT NULL DEFAULT 'structured',
    bpm          INTEGER,
    music_key    TEXT,
    scale        TEXT,
    vocal        TEXT NOT NULL DEFAULT '',
    pro_tip      TEXT NOT NULL DEFAULT '',
    created_at   REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS prompt_segments (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    prompt_id  INTEGER NOT NULL REFERENCES prompts(id) ON DELETE CASCADE,
    section    TEXT NOT NULL,
    field      TEXT NOT NULL,
    ordinal    INTEGER NOT NULL DEFAULT 0,
    content    TEXT NOT NULL,
    enabled    INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS keywords (
    id    INTEGER PRIMARY KEY AUTOINCREMENT,
    term  TEXT UNIQUE NOT NULL,
    kind  TEXT NOT NULL DEFAULT 'keyword',
    uses  INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS prompt_keywords (
    prompt_id   INTEGER NOT NULL REFERENCES prompts(id) ON DELETE CASCADE,
    keyword_id  INTEGER NOT NULL REFERENCES keywords(id) ON DELETE CASCADE,
    PRIMARY KEY (prompt_id, keyword_id)
);

CREATE TABLE IF NOT EXISTS jobs (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    batch_id    TEXT NOT NULL,
    model_id    TEXT NOT NULL REFERENCES models(id),
    prompt_id   INTEGER REFERENCES prompts(id),
    caption     TEXT NOT NULL,
    lyrics      TEXT,
    seed        INTEGER,
    params      TEXT NOT NULL DEFAULT '{}',
    status      TEXT NOT NULL DEFAULT 'queued',
    position    INTEGER NOT NULL DEFAULT 0,
    progress    REAL NOT NULL DEFAULT 0.0,
    output_file TEXT,
    error       TEXT,
    created_at  REAL NOT NULL,
    started_at  REAL,
    finished_at REAL
);

CREATE TABLE IF NOT EXISTS generations (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id       INTEGER REFERENCES jobs(id),
    prompt_id    INTEGER REFERENCES prompts(id),
    model_id     TEXT NOT NULL REFERENCES models(id),
    caption      TEXT NOT NULL,
    lyrics       TEXT,
    seed         INTEGER NOT NULL,
    duration     REAL NOT NULL,
    steps        INTEGER NOT NULL,
    format       TEXT NOT NULL,
    output_file  TEXT NOT NULL,
    sidecar_file TEXT,
    size_mb      REAL NOT NULL DEFAULT 0.0,
    elapsed_sec  REAL NOT NULL DEFAULT 0.0,
    songwriter_id TEXT,
    songwriter_revision INTEGER,
    songwriter_generation_uuid TEXT,
    songwriter_remote_generation_id TEXT,
    songwriter_report_status TEXT CHECK(songwriter_report_status IN ('pending','completed','failed')),
    songwriter_report_error TEXT,
    analysis     TEXT,
    analyzed_at  REAL,
    created_at   REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_generations_songwriter_report
    ON generations(songwriter_report_status, created_at);

CREATE TABLE IF NOT EXISTS songbench_evaluations (
    generation_id INTEGER PRIMARY KEY REFERENCES generations(id) ON DELETE CASCADE,
    status TEXT NOT NULL CHECK(status IN ('installing','evaluating','completed','failed')),
    melody REAL,
    arrangement REAL,
    musicality REAL,
    vocal REAL,
    instrumental REAL,
    mixing REAL,
    structure REAL,
    overall REAL,
    device TEXT,
    evaluator_version TEXT NOT NULL DEFAULT 'songbench-mlx-bf16-v1',
    elapsed_sec REAL NOT NULL DEFAULT 0.0,
    error TEXT,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_songbench_status ON songbench_evaluations(status);
"""

def connect(path: Path | str | None = None) -> sqlite3.Connection:
    target = Path(path) if path else DB_PATH
    target.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(str(target), timeout=10.0)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA foreign_keys = ON")
    return con

def emit(event: str, component: str = "app", level: str = "info", **kw) -> None:
    """Emit one JSON event on stdout for SwiftUI app with component and level."""
    payload = {"event": event, "component": component, "level": level}
    payload.update(kw)
    print(json.dumps(payload), flush=True)

# ===========================================================================
# Model Catalog & Seeding
# ===========================================================================

FALLBACK_MODELS_ROOTS = [
    MODELS_DIR,
    Path.home() / "Library/Application Support/YuE2Mac/Models",
]


def find_weights_path(weights_rel: str) -> Path | None:
    """Search for weights path in standard ~/.MusicStudio/models or fallback locations."""
    clean_rel = weights_rel.removeprefix("models/").lstrip("/")
    targets = [Path(clean_rel), Path(weights_rel)]
    for target_rel in targets:
        p1 = MODELS_DIR / target_rel
        if (p1 / "config.json").exists() or (p1 / "model.safetensors").exists() or (p1 / "conversion.json").exists():
            return p1

        for root in FALLBACK_MODELS_ROOTS:
            cand = root / target_rel
            if (cand / "config.json").exists() or (cand / "model.safetensors").exists() or (cand / "conversion.json").exists():
                return cand
            cand2 = root / target_rel.name
            if (cand2 / "config.json").exists() or (cand2 / "model.safetensors").exists() or (cand2 / "conversion.json").exists():
                return cand2
            cand3 = root / "mlx-community" / target_rel.name
            if (cand3 / "config.json").exists() or (cand3 / "model.safetensors").exists() or (cand3 / "conversion.json").exists():
                return cand3
    return None

def find_vae_path() -> Path | None:
    """Locate VAE directory for mlx-yue."""
    candidates = [
        MODELS_DIR / "m-a-p" / "YuE2-Vae",
        MODELS_DIR / "YuE2-Vae",
    ]
    for root in FALLBACK_MODELS_ROOTS:
        candidates.append(root / "m-a-p" / "YuE2-Vae")
        candidates.append(root / "YuE2-Vae")
    hf_cache = Path.home() / ".cache/huggingface/hub/models--m-a-p--YuE2-Vae/snapshots"
    if hf_cache.exists():
        for snap in hf_cache.iterdir():
            if snap.is_dir():
                candidates.append(snap)
    for c in candidates:
        if (c / "config.json").exists() and ((c / "model.safetensors").exists() or (c / "vae.safetensors").exists()):
            return c
    return None

def find_yue2_engine_script() -> Path | None:
    """Locate YuE2 generate.py script."""
    candidates = [
        ENGINES_DIR / "yue2" / "generate.py",
        STUDIO_DIR / "engines" / "yue2" / "generate.py",
        Path.home() / "Library/Application Support/YuE2Mac/Scripts/generate.py",
    ]
    for c in candidates:
        if c.exists():
            return c
    return None
def prepare_yue2_conversion(model_path: Path) -> None:
    """Reconcile optional precision entries with the converted files on disk.

    Lyra validates the whole shared conversion directory before loading one precision.
    A stale optional precision record must not prevent an intact BF16 model from running.
    """
    model_path = Path(model_path).resolve()
    manifest_path = model_path / "conversion.json"
    if not manifest_path.is_file():
        return
    for metadata_file in model_path.rglob(".DS_Store"):
        metadata_file.unlink(missing_ok=True)
    manifest = json.loads(manifest_path.read_text("utf-8"))
    precisions = manifest.get("precisions")
    files = manifest.get("files")
    if not isinstance(precisions, dict) or not isinstance(files, dict):
        raise ValueError("YuE2 conversion manifest is malformed")
    changed = False
    for precision in ("8bit", "4bit"):
        filename = f"ar-{precision}.safetensors"
        if precision in precisions and not (model_path / filename).is_file():
            precisions.pop(precision, None)
            files.pop(filename, None)
            changed = True
    if changed:
        temporary = manifest_path.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", "utf-8")
        os.replace(temporary, manifest_path)


def child_process_error(label: str, returncode: int, output_tail: deque[str]) -> RuntimeError:
    detail = next(
        (line for line in reversed(output_tail) if line.startswith(("ValueError:", "RuntimeError:", "FileNotFoundError:"))),
        output_tail[-1] if output_tail else f"exit {returncode}",
    )
    return RuntimeError(f"{label} failed: {detail}"[:500])


def seed_models(con: sqlite3.Connection) -> None:
    now = time.time()

    # Read catalog.json if available
    catalog_path = STUDIO_DIR / "catalog.json"
    catalog_models = []
    if catalog_path.exists():
        try:
            data = json.loads(catalog_path.read_text("utf-8"))
            catalog_models = data.get("models", [])
        except Exception:
            pass

    # Check MLX availability
    have_mlx = False
    why_mlx = None
    try:
        import mlx.core  # noqa: F401
        have_mlx = True
    except Exception as e:
        why_mlx = f"mlx not installed: {e}"

    yue2_script = find_yue2_engine_script()

    for m in catalog_models:
        mid = m["id"]
        name = m["name"]
        family = m["family"]
        backend = m["backend"]
        rel_path = m["weights_path"]
        caps = json.dumps(m.get("capabilities", {}))
        sort_order = m.get("sort_order", 100)

        found_path = find_weights_path(rel_path)
        yue2_prepare_error = None
        if family == "yue2" and found_path:
            try:
                prepare_yue2_conversion(found_path)
            except Exception as error:
                yue2_prepare_error = f"YuE2 model validation failed: {error}"
        available = False
        reason = None

        have_lyra = False
        try:
            import lyra
            have_lyra = True
        except ImportError:
            pass

        if not found_path:
            reason = f"Weights not found (checked ~/.MusicStudio/models/{rel_path})"
        elif not have_mlx:
            reason = why_mlx
        elif family == "yue2" and yue2_prepare_error:
            reason = yue2_prepare_error
        elif family == "yue2" and not have_lyra and not yue2_script:
            reason = "YuE2 engine (mlx-yue) not installed in venv"
        elif family == "yue2" and not (found_path / f"ar-{m.get('quantization', 'bf16')}.safetensors").is_file():
            reason = f"YuE2 {m.get('quantization', 'bf16')} weights are not installed"
        else:
            available = True

        actual_path_str = str(found_path.resolve()) if found_path else rel_path

        con.execute(
            """INSERT INTO models (id, name, family, backend, weights_path,
                                   available, unavailable_reason, license,
                                   capabilities, sort_order, created_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT(id) DO UPDATE SET
                   name=excluded.name,
                   family=excluded.family,
                   backend=excluded.backend,
                   weights_path=excluded.weights_path,
                   available=excluded.available,
                   unavailable_reason=excluded.unavailable_reason,
                   capabilities=excluded.capabilities,
                   sort_order=excluded.sort_order;
            """,
            (mid, name, family, backend, actual_path_str, int(available), reason,
             m.get("license", "Apache-2.0"), caps, sort_order, now)
        )
    con.commit()

# ===========================================================================
# Prompt Formatting & Parsing
# ===========================================================================

def assemble_caption(segments) -> str:
    """Rebuild a structured caption from enabled segments."""
    by_section: dict[str, list[tuple[int, str, str]]] = {}
    for s in segments:
        if not s["enabled"]:
            continue
        sec = s["section"]
        by_section.setdefault(sec, []).append((s["ordinal"], s["field"], s["content"]))

    lines: list[str] = []
    section_order = ("global_metadata", "vocal_details", "arrangement", "lyrics", "raw")
    section_headers = {
        "global_metadata": "Global Metadata",
        "vocal_details": "Vocal Details",
        "arrangement": "Arrangement",
        "lyrics": "Lyrics",
    }

    for sec in section_order:
        entries = by_section.get(sec)
        if not entries:
            continue
        entries.sort(key=lambda x: x[0])
        header = section_headers.get(sec)
        if header:
            if lines:
                lines.append("")
            lines.append(f"{header}:")
        for _, field, content in entries:
            if sec == "raw":
                lines.append(content)
            else:
                lbl = FIELD_CAPTION_LABEL.get((sec, field), field)
                if content:
                    lines.append(f"{lbl}: {content}")
                else:
                    lines.append(f"{lbl}:")

    return "\n".join(lines).strip()

def caption_to_style(caption: str) -> str:
    """Extract a concise style tagline for YuE2 from a structured caption."""
    lines = [ln.strip() for ln in caption.splitlines() if ln.strip()]
    style_bits = []
    for ln in lines:
        lower = ln.lower()
        if lower.endswith(":") and ("metadata" in lower or "vocal" in lower or "arrangement" in lower):
            continue
        if ":" in ln:
            _, _, val = ln.partition(":")
            val = val.strip()
            if val and len(val) < 80:
                style_bits.append(val)
        else:
            if len(ln) < 80 and not ln.startswith("["):
                style_bits.append(ln)
    if style_bits:
        return ", ".join(style_bits[:6])
    return lines[0] if lines else "indie pop, acoustic guitar, warm vocal"

def render_for_model(con: sqlite3.Connection, prompt_id: int, model_id: str) -> str:
    row = con.execute("SELECT capabilities, family FROM models WHERE id = ?", (model_id,)).fetchone()
    caps = json.loads(row["capabilities"]) if row else {}
    family = row["family"] if row else ("yue2" if "yue2" in model_id.lower() else "minimax_music3")
    fmt = caps.get("prompt_format", "structured" if family == "minimax_music3" else "tagline")

    if fmt == "tagline" or family == "yue2":
        # FR-011 Authoritative YuE2 style line:
        # language -> genre -> vocal character -> instruments -> groove/mood -> BPM -> exclusions
        p = con.execute(
            """SELECT title, genre, subgenre, bpm, music_key, scale, vocal,
                      time_signature, vocal_register, language, core_palette
               FROM prompts WHERE id = ?""",
            (prompt_id,),
        ).fetchone()

        bits: list[str] = []
        if p:
            # 1. Language
            lang = (p["language"] or "").strip().lower()
            if lang and lang != "instrumental" and lang != "english":
                bits.append(lang.capitalized())
            elif lang == "english":
                bits.append("English")

            # 2. Genre / subgenre
            genres = []
            if p["genre"]: genres.append(p["genre"].lower())
            if p["subgenre"] and p["subgenre"].lower() != (p["genre"] or "").lower():
                genres.append(p["subgenre"].lower())
            if genres:
                bits.append(" / ".join(genres))

            # 3. Vocal character (register + vocal type)
            if p["vocal"] == "instrumental":
                bits.append("instrumental, no vocals")
            else:
                voc_parts = []
                if p["vocal_register"] and p["vocal_register"] != "none":
                    voc_parts.append(p["vocal_register"].lower())
                if p["vocal"] and p["vocal"] != "unknown":
                    voc_parts.append(p["vocal"].lower())
                if voc_parts:
                    bits.append(" ".join(voc_parts))

            # 4. Instruments (from core_palette and prompt_keywords)
            if p["core_palette"]:
                bits.append(p["core_palette"].lower())

            inst_rows = con.execute("""
                SELECT k.term FROM prompt_keywords pk
                JOIN keywords k ON k.id = pk.keyword_id
                WHERE pk.prompt_id = ? AND k.kind = 'instrument'
                ORDER BY k.uses DESC LIMIT 4
            """, (prompt_id,)).fetchall()
            insts = [r["term"].lower() for r in inst_rows if r["term"].lower() not in " ".join(bits)]
            if insts:
                bits.append(", ".join(insts))

            # 5. Groove & Mood (from prompt_keywords)
            mood_rows = con.execute("""
                SELECT k.term FROM prompt_keywords pk
                JOIN keywords k ON k.id = pk.keyword_id
                WHERE pk.prompt_id = ? AND k.kind = 'mood'
                ORDER BY k.uses DESC LIMIT 3
            """, (prompt_id,)).fetchall()
            moods = [r["term"].lower() for r in mood_rows if r["term"].lower() not in " ".join(bits)]
            if moods:
                bits.append(", ".join(moods))

            # 6. BPM & Time Signature
            if p["bpm"]:
                bits.append(f"{p['bpm']} BPM")
            if p["time_signature"] and p["time_signature"] != "4/4":
                bits.append(f"{p['time_signature']} time")

        style_line = ", ".join(b for b in bits if b)
        emit("log", component="template", level="info", message="Rendered YuE2 style tagline", detail=f"words={len(style_line.split())} chars={len(style_line)}")
        return style_line

    segs = con.execute(
        """SELECT section, field, ordinal, content, enabled
           FROM prompt_segments WHERE prompt_id = ? AND enabled = 1
           ORDER BY section, field, ordinal""",
        (prompt_id,),
    ).fetchall()
    caption = assemble_caption(segs)
    emit("log", component="template", level="info", message="Rendered MiniMax structured caption", detail=f"chars={len(caption)} segments={len(segs)}")
    return caption


# ===========================================================================
# Loudness Normalisation (FR-009)
# Target: -14.0 LUFS integrated · -1.0 dBTP true peak
# Uses mlx_audio.dsp (ITU-R BS.1770 chain) with non-destructive backup
# ===========================================================================

def normalize_audio_lufs(
    wav_path: Path,
    target_lufs: float = -14.0,
    target_peak_db: float = -1.0
) -> tuple[Path, float, float, float, float, Path]:
    """
    Non-destructive loudness normalisation using mlx_audio.dsp.
    Returns (norm_wav_path, measured_lufs, gain_db, pre_peak_db, post_peak_db, raw_wav_path).
    """
    import wave
    import numpy as np
    from mlx_audio.dsp import integrated_loudness, normalize_loudness

    wav_file = Path(wav_path).resolve()
    if not wav_file.exists():
        raise FileNotFoundError(f"Audio file not found: {wav_file}")

    with wave.open(str(wav_file), "rb") as w:
        rate = w.getframerate()
        ch = w.getnchannels()
        sampwidth = w.getsampwidth()
        nframes = w.getnframes()
        frames = w.readframes(nframes)

    if sampwidth == 2:
        audio = np.frombuffer(frames, dtype=np.int16).astype(np.float64) / 32768.0
    elif sampwidth == 3:
        raw = np.frombuffer(frames, dtype=np.uint8).reshape(-1, 3)
        int32_arr = (raw[:, 0].astype(np.int32) |
                     (raw[:, 1].astype(np.int32) << 8) |
                     (raw[:, 2].astype(np.int32) << 16))
        int32_arr = np.where(int32_arr & 0x800000, int32_arr | ~0xFFFFFF, int32_arr)
        audio = int32_arr.astype(np.float64) / 8388608.0
    elif sampwidth == 4:
        audio = np.frombuffer(frames, dtype=np.int32).astype(np.float64) / 2147483648.0
    else:
        audio = np.frombuffer(frames, dtype=np.float32).astype(np.float64)

    if ch == 2:
        audio = audio.reshape(-1, 2)

    # 1. Measure input integrated loudness (ITU-R BS.1770)
    measured_lufs = float(integrated_loudness(audio, rate))
    pre_peak = float(np.max(np.abs(audio)))
    pre_peak_db = float(20.0 * math.log10(max(pre_peak, 1e-9)))

    # 2. Compute gain
    gain_db = target_lufs - measured_lufs
    gain_sign = "+" if gain_db >= 0 else ""

    emit("log", component="loudness", level="info",
         message=f"Measured {measured_lufs:.2f} LUFS (gain {gain_sign}{gain_db:.2f}dB -> {target_lufs:.0f})",
         detail=f"lufs={measured_lufs:.2f} target={target_lufs} gain_db={gain_db:.2f}")

    # 3. Apply loudness normalisation
    norm_audio = normalize_loudness(audio, measured_lufs, target_lufs)

    # 4. Apply transparent peak limiter if peak exceeds target_peak_db
    target_peak_linear = 10.0 ** (target_peak_db / 20.0) # ~0.89125
    post_peak_before = float(np.max(np.abs(norm_audio)))

    limiter_applied = False
    if post_peak_before > target_peak_linear:
        limiter_applied = True
        thresh = target_peak_linear * 0.90
        excess = np.maximum(0.0, np.abs(norm_audio) - thresh)
        mask = excess > 0
        knee_range = target_peak_linear - thresh
        compressed_excess = knee_range * np.tanh(excess[mask] / knee_range)
        norm_audio[mask] = np.sign(norm_audio[mask]) * (thresh + compressed_excess)

    post_peak = float(np.max(np.abs(norm_audio)))
    post_peak_db = float(20.0 * math.log10(max(post_peak, 1e-9)))

    limiter_note = "limiter applied" if limiter_applied else "within headroom"
    emit("log", component="loudness", level="info",
         message=f"Peak {pre_peak_db:.2f} -> {post_peak_db:.2f} dBTP ({limiter_note})",
         detail=f"pre_peak_db={pre_peak_db:.2f} post_peak_db={post_peak_db:.2f} limiter={limiter_applied}")

    # 5. Retain original unprocessed file non-destructively
    raw_wav_path = wav_file.with_name(f"{wav_file.stem}_raw.wav")
    if not raw_wav_path.exists():
        shutil.copy2(wav_file, raw_wav_path)
        emit("log", component="loudness", level="debug",
             message=f"Retained unprocessed audio: {raw_wav_path.name}")

    # 6. Write normalised audio back to wav_file (16-bit PCM for universal compatibility)
    clipped = np.clip(norm_audio, -1.0, 1.0)
    out_int16 = (clipped * 32767.0).astype(np.int16)

    with wave.open(str(wav_file), "wb") as w:
        w.setnchannels(ch)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(out_int16.tobytes())

    return wav_file, measured_lufs, gain_db, pre_peak_db, post_peak_db, raw_wav_path

# ===========================================================================
# Full-Track Analysis + Metadata Tagging
# ===========================================================================

# Krumhansl-Schmuckler major/minor key profiles for template-matching key detection.
_KS_MAJOR = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
_KS_MINOR = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
_PITCH_CLASSES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
_CAMELOT = {
    ("C", "major"): "8B", ("C#", "major"): "3B", ("D", "major"): "10B", ("D#", "major"): "5B",
    ("E", "major"): "12B", ("F", "major"): "7B", ("F#", "major"): "2B", ("G", "major"): "9B",
    ("G#", "major"): "4B", ("A", "major"): "11B", ("A#", "major"): "6B", ("B", "major"): "1B",
    ("C", "minor"): "5A", ("C#", "minor"): "12A", ("D", "minor"): "7A", ("D#", "minor"): "2A",
    ("E", "minor"): "9A", ("F", "minor"): "4A", ("F#", "minor"): "11A", ("G", "minor"): "6A",
    ("G#", "minor"): "1A", ("A", "minor"): "8A", ("A#", "minor"): "3A", ("B", "minor"): "10A",
}


def _detect_key(chroma_mean) -> tuple[str, str, str]:
    """Correlate the mean chromagram against KS profiles. Returns (tonic, mode, camelot)."""
    import numpy as np

    def _corr(a, b):
        a = a - a.mean()
        b = b - b.mean()
        denom = (np.linalg.norm(a) * np.linalg.norm(b)) or 1e-9
        return float(np.dot(a, b) / denom)

    maj = np.asarray(_KS_MAJOR)
    minr = np.asarray(_KS_MINOR)
    best = (-2.0, "C", "major")
    for i in range(12):
        rolled = np.roll(chroma_mean, -i)  # align candidate tonic to index 0
        cm = _corr(rolled, maj)
        if cm > best[0]:
            best = (cm, _PITCH_CLASSES[i], "major")
        cmin = _corr(rolled, minr)
        if cmin > best[0]:
            best = (cmin, _PITCH_CLASSES[i], "minor")
    tonic, mode = best[1], best[2]
    return tonic, mode, _CAMELOT.get((tonic, mode), "")


def analyze_audio(audio_path: str | Path, lufs_info: dict | None = None) -> dict:
    """Extract measured musical + loudness metrics from a rendered track.

    Tempo, beat count, onset rate, key/scale, and spectral mood descriptors come from
    librosa; loudness/true-peak are reused from the LUFS normaliser (lufs_info) when
    available rather than recomputed. Best-effort: returns {} on failure so tagging
    still proceeds with DB/generation metadata.
    """
    import numpy as np

    path = Path(audio_path)
    if not path.exists():
        return {}
    try:
        import librosa
    except ImportError:
        emit("log", component="analysis", level="warn", message="librosa unavailable; skipping audio analysis")
        return {}

    try:
        y, sr = librosa.load(str(path), sr=22050, mono=True)
    except Exception as e:
        emit("log", component="analysis", level="warn", message=f"Could not load audio for analysis: {e}")
        return {}

    if y.size == 0:
        return {}

    result: dict[str, object] = {}
    try:
        tempo, beats = librosa.beat.beat_track(y=y, sr=sr)
        bpm = float(np.atleast_1d(tempo)[0])
        if math.isfinite(bpm) and bpm > 0:
            result["bpm"] = round(bpm, 1)
            result["beat_count"] = int(len(beats))
    except Exception as e:
        emit("log", component="analysis", level="debug", message=f"Tempo estimation failed: {e}")

    try:
        dur = float(librosa.get_duration(y=y, sr=sr))
        if dur > 0:
            result["duration_ms"] = int(round(dur * 1000))
        onset_times = librosa.onset.onset_detect(y=y, sr=sr, units="time")
        result["onset_rate_hz"] = round(len(onset_times) / (dur or 1e-9), 3)
    except Exception as e:
        emit("log", component="analysis", level="debug", message=f"Onset detection failed: {e}")

    # EBU R128 Loudness Range (LRA): spread of short-term loudness (P95 - P10).
    try:
        from mlx_audio.dsp import integrated_loudness
        mono = y if y.ndim == 1 else y.mean(axis=0)
        win = int(sr * 3.0)   # 3s short-term window
        hop = int(sr * 1.0)   # 1s hop
        st_loudness = []
        for start in range(0, max(len(mono) - win, 0) + 1, hop):
            block = mono[start:start + win]
            if len(block) < win:
                break
            lv = float(integrated_loudness(block, sr))
            if math.isfinite(lv) and lv > -70.0:   # EBU absolute gate
                st_loudness.append(lv)
        if len(st_loudness) >= 2:
            arr = np.sort(np.asarray(st_loudness))
            p10 = float(np.percentile(arr, 10))
            p95 = float(np.percentile(arr, 95))
            result["lra_lu"] = round(p95 - p10, 2)
    except Exception as e:
        emit("log", component="analysis", level="debug", message=f"LRA computation failed: {e}")

    try:
        chroma = librosa.feature.chroma_cqt(y=y, sr=sr)
        chroma_mean = chroma.mean(axis=1)
        tonic, mode, camelot = _detect_key(chroma_mean)
        result["key"] = tonic
        result["scale"] = mode
        if camelot:
            result["camelot"] = camelot
    except Exception as e:
        emit("log", component="analysis", level="debug", message=f"Key detection failed: {e}")

    try:
        centroid = float(np.mean(librosa.feature.spectral_centroid(y=y, sr=sr)))
        rolloff = float(np.mean(librosa.feature.spectral_rolloff(y=y, sr=sr)))
        zcr = float(np.mean(librosa.feature.zero_crossing_rate(y)))
        rms = float(np.mean(librosa.feature.rms(y=y)))
        result["spectral_centroid_hz"] = round(centroid, 1)
        result["spectral_rolloff_hz"] = round(rolloff, 1)
        result["zero_crossing_rate"] = round(zcr, 4)
        result["rms_energy"] = round(rms, 4)
        # Coarse brightness/energy mood descriptor from centroid + rms.
        bright = "bright" if centroid > 2600 else ("warm" if centroid > 1500 else "dark")
        energetic = "energetic" if rms > 0.12 else ("moderate" if rms > 0.05 else "mellow")
        result["mood_descriptor"] = f"{energetic}, {bright}"
    except Exception as e:
        emit("log", component="analysis", level="debug", message=f"Spectral analysis failed: {e}")

    if lufs_info:
        for k in ("lufs", "gain_db", "pre_peak_db", "post_peak_db"):
            if k in lufs_info:
                result[k] = lufs_info[k]

    emit("log", component="analysis", level="info",
         message=f"Analysed track: {result.get('bpm', '?')} BPM, "
                 f"{result.get('key', '?')} {result.get('scale', '')}, "
                 f"{result.get('mood_descriptor', 'n/a')}",
         detail=json.dumps(result))
    return result


def _tag_text(value) -> str:
    return "" if value is None else str(value).strip()


_NOTE_TO_TKEY = {
    "C": "C", "C#": "C#", "DB": "C#", "D": "D", "D#": "D#", "EB": "D#",
    "E": "E", "F": "F", "F#": "F#", "GB": "F#", "G": "G", "G#": "G#",
    "AB": "G#", "A": "A", "A#": "A#", "BB": "A#", "B": "B",
}


def _tkey_grammar(key: str, scale: str) -> str:
    """Format key+scale into the ID3v2 TKEY grammar (e.g. 'A', 'Am', 'F#m').

    Returns "" if the key cannot be mapped to the restricted TKEY alphabet so strict
    players (Mixxx/Serato/rekordbox) don't choke on free text.
    """
    k = (key or "").strip()
    if not k:
        return ""
    root = _NOTE_TO_TKEY.get(k.upper())
    if root is None:
        return ""
    minor = (scale or "").strip().lower().startswith("min")
    return root + ("m" if minor else "")


def tag_audio_file(path: str | Path, meta: dict) -> bool:
    """Write metadata into an audio file's native tag container.

    Supports mp3 (ID3v2.4), m4a/aac (MP4 atoms), flac (Vorbis), and wav (RIFF via ID3).

    Recognised standard keys: title, artist, album, album_artist, genre, composer,
    bpm (measured), key + scale (-> TKEY grammar), duration_ms (-> TLEN), comment,
    lyrics.

    Namespaced custom groups (each an optional dict in `meta`) are written as prefixed
    TXXX frames / freeform MP4 atoms / Vorbis comments and read back by read_audio_tags:
      gen    -> GEN_*     diffusion provenance (model, seed, steps, guidance, vocal, ...)
      target -> TARGET_*  prompt's intended ground-truth (target_bpm, target_key)
      dsp    -> DSP_*     acoustic analysis (spectral_centroid, onset_rate, camelot, ...)
      norm   -> NORM_*    loudness/dynamics (lufs, lra_lu, gain_db, pre_peak_db, ...)
      sb     -> SB_*      SongBench scores (score_overall, melody, ...)
    A GEN_GENERATION_PARAMS JSON blob is emitted when `gen` is present.

    Returns True on success. Best-effort: logs and returns False on failure.
    """
    p = Path(path)
    if not p.exists():
        return False
    ext = p.suffix.lower().lstrip(".")

    title = _tag_text(meta.get("title"))
    artist = _tag_text(meta.get("artist")) or "MusicStudio"
    album_artist = _tag_text(meta.get("album_artist")) or "MusicStudio"
    album = _tag_text(meta.get("album"))
    genre = _tag_text(meta.get("genre"))
    composer = _tag_text(meta.get("composer"))
    comment = _tag_text(meta.get("comment"))
    lyrics = _tag_text(meta.get("lyrics"))
    bpm = meta.get("bpm")
    tkey = _tkey_grammar(_tag_text(meta.get("key")), _tag_text(meta.get("scale")))
    duration_ms = meta.get("duration_ms")

    # Namespaced custom groups: {prefix: {key: value}}.
    groups: dict[str, dict] = {}
    for prefix in ("gen", "target", "dsp", "norm", "sb"):
        g = meta.get(prefix)
        if isinstance(g, dict):
            clean = {k: _tag_text(v) for k, v in g.items() if v not in (None, "")}
            if clean:
                groups[prefix.upper()] = clean
    # Provenance safety net: full generation params as one JSON string.
    if "gen" in meta and isinstance(meta["gen"], dict) and meta["gen"]:
        groups.setdefault("GEN", {})["generation_params"] = json.dumps(
            {k: v for k, v in meta["gen"].items() if v not in (None, "")},
            separators=(",", ":"), sort_keys=True,
        )

    def _flat_customs():
        for prefix, g in groups.items():
            for k, v in g.items():
                yield f"{prefix}_{k.upper()}", v   # e.g. GEN_SEED, DSP_CAMELOT

    try:
        if ext == "mp3" or ext == "wav":
            from mutagen.id3 import (
                ID3, ID3NoHeaderError, TIT2, TPE1, TPE2, TALB, TCON, TBPM, TKEY,
                TLEN, TCOM, COMM, USLT, TXXX,
            )
            if ext == "wav":
                from mutagen.wave import WAVE
                audio = WAVE(str(p))
                if audio.tags is None:
                    audio.add_tags()
                tags = audio.tags
            else:
                try:
                    tags = ID3(str(p))
                except ID3NoHeaderError:
                    tags = ID3()
            if title:
                tags.add(TIT2(encoding=3, text=title))
            if artist:
                tags.add(TPE1(encoding=3, text=artist))
            if album_artist:
                tags.add(TPE2(encoding=3, text=album_artist))
            if album:
                tags.add(TALB(encoding=3, text=album))
            if genre:
                tags.add(TCON(encoding=3, text=genre))
            if composer:
                tags.add(TCOM(encoding=3, text=composer))
            if bpm not in (None, ""):
                tags.add(TBPM(encoding=3, text=str(int(round(float(bpm))))))
            if tkey:
                tags.add(TKEY(encoding=3, text=tkey))
            if duration_ms not in (None, ""):
                tags.add(TLEN(encoding=3, text=str(int(duration_ms))))
            if comment:
                tags.add(COMM(encoding=3, lang="eng", desc="", text=comment))
            if lyrics:
                tags.add(USLT(encoding=3, lang="eng", desc="", text=lyrics))
            for desc, v in _flat_customs():
                tags.add(TXXX(encoding=3, desc=desc, text=v))
            if ext == "wav":
                audio.save()
            else:
                tags.save(str(p), v2_version=4)

        elif ext in ("m4a", "mp4", "aac"):
            from mutagen.mp4 import MP4
            audio = MP4(str(p))
            if title:
                audio["\xa9nam"] = title
            if artist:
                audio["\xa9ART"] = artist
            if album_artist:
                audio["aART"] = album_artist
            if album:
                audio["\xa9alb"] = album
            if genre:
                audio["\xa9gen"] = genre
            if composer:
                audio["\xa9wrt"] = composer
            if comment:
                audio["\xa9cmt"] = comment
            if lyrics:
                audio["\xa9lyr"] = lyrics
            if bpm not in (None, ""):
                audio["tmpo"] = [int(round(float(bpm)))]
            if tkey:
                audio["----:com.apple.iTunes:initialkey"] = tkey.encode("utf-8")
            for desc, v in _flat_customs():
                audio[f"----:com.apple.iTunes:{desc}"] = v.encode("utf-8")
            audio.save()

        elif ext == "flac":
            from mutagen.flac import FLAC
            audio = FLAC(str(p))
            if title:
                audio["title"] = title
            if artist:
                audio["artist"] = artist
            if album_artist:
                audio["albumartist"] = album_artist
            if album:
                audio["album"] = album
            if genre:
                audio["genre"] = genre
            if composer:
                audio["composer"] = composer
            if comment:
                audio["comment"] = comment
            if lyrics:
                audio["lyrics"] = lyrics
            if bpm not in (None, ""):
                audio["bpm"] = str(int(round(float(bpm))))
            if tkey:
                audio["initialkey"] = tkey
            for desc, v in _flat_customs():
                audio[desc.lower()] = v
            audio.save()
        else:
            emit("log", component="tag", level="warn", message=f"No tag writer for .{ext}; skipping")
            return False
    except Exception as e:
        emit("log", component="tag", level="warn", message=f"Tagging failed for {p.name}: {e}")
        return False

    emit("log", component="tag", level="info",
         message=f"Tagged {p.name} ({ext}): title='{title}' bpm={bpm} key='{tkey}' "
                 f"groups={sorted(groups)}")
    return True


def read_audio_tags(path: str | Path) -> dict:
    """Read tags from an audio file into a tag_audio_file()-shaped dict.

    Standard keys (title/artist/album_artist/album/genre/composer/bpm/key/
    duration_ms/comment/lyrics) plus namespaced custom groups reconstructed into
    nested dicts: gen/target/dsp/norm/sb. Symmetric with tag_audio_file so conversions
    round-trip. Best-effort: returns {} on failure or unsupported container.
    """
    p = Path(path)
    if not p.exists():
        return {}
    ext = p.suffix.lower().lstrip(".")
    out: dict[str, object] = {}
    _PREFIXES = ("GEN", "TARGET", "DSP", "NORM", "SB")

    def _stash_custom(desc: str, value) -> None:
        """Route a prefixed custom key back into its group dict (e.g. GEN_SEED -> gen.seed)."""
        for pre in _PREFIXES:
            if desc.startswith(pre + "_"):
                grp = out.setdefault(pre.lower(), {})
                grp[desc[len(pre) + 1:].lower()] = value
                return

    try:
        if ext in ("mp3", "wav"):
            from mutagen.id3 import ID3, ID3NoHeaderError
            if ext == "wav":
                from mutagen.wave import WAVE
                tags = WAVE(str(p)).tags
                if tags is None:
                    return {}
            else:
                try:
                    tags = ID3(str(p))
                except ID3NoHeaderError:
                    return {}
            frame_map = {"TIT2": "title", "TPE1": "artist", "TPE2": "album_artist",
                         "TALB": "album", "TCON": "genre", "TCOM": "composer",
                         "TBPM": "bpm", "TKEY": "key", "TLEN": "duration_ms"}
            for fid, key in frame_map.items():
                if fid in tags:
                    out[key] = str(tags[fid].text[0])
            if "COMM::eng" in tags:
                out["comment"] = str(tags["COMM::eng"].text[0])
            if "USLT::eng" in tags:
                out["lyrics"] = str(tags["USLT::eng"].text)
            for frame in tags.getall("TXXX"):
                _stash_custom(frame.desc or "", str(frame.text[0]))
        elif ext in ("m4a", "mp4", "aac"):
            from mutagen.mp4 import MP4
            audio = MP4(str(p))
            atom_map = {"\xa9nam": "title", "\xa9ART": "artist", "aART": "album_artist",
                        "\xa9alb": "album", "\xa9gen": "genre", "\xa9wrt": "composer",
                        "\xa9cmt": "comment", "\xa9lyr": "lyrics"}
            for atom, key in atom_map.items():
                if atom in audio:
                    out[key] = str(audio[atom][0])
            if "tmpo" in audio:
                out["bpm"] = int(audio["tmpo"][0])
            if getattr(audio, "info", None) and getattr(audio.info, "length", None):
                out["duration_ms"] = int(round(audio.info.length * 1000))
            for atom, vals in audio.items():
                if atom.startswith("----:com.apple.iTunes:"):
                    name = atom.split(":")[-1]
                    val = bytes(vals[0]).decode("utf-8", "ignore")
                    if name == "initialkey":
                        out["key"] = val
                    else:
                        _stash_custom(name, val)
        elif ext == "flac":
            from mutagen.flac import FLAC
            audio = FLAC(str(p))
            direct = {"title": "title", "artist": "artist", "albumartist": "album_artist",
                      "album": "album", "genre": "genre", "composer": "composer",
                      "comment": "comment", "lyrics": "lyrics", "bpm": "bpm"}
            for vk, key in direct.items():
                if vk in audio:
                    out[key] = audio[vk][0]
            if "initialkey" in audio:
                out["key"] = audio["initialkey"][0]
            if getattr(audio, "info", None) and getattr(audio.info, "length", None):
                out["duration_ms"] = int(round(audio.info.length * 1000))
            for k, v in audio.items():
                _stash_custom(k.upper(), v[0])
    except Exception as e:
        emit("log", component="tag", level="debug", message=f"Could not read tags from {p.name}: {e}")
        return {}
    return out


# ===========================================================================
# Production / DSP Tooling (FR-013)
# Opt-in mastering chain:
# 1. Artifact reduction (pedalboard NoiseGate, bounded)
# 2. High-frequency repair (pedalboard HighShelfFilter >10kHz)
# 3. 3-Band mastering EQ (pedalboard LowShelf/Peak/HighShelf)
# 4. Mastering glue (pedalboard Compressor + Limiter)
# 5. Loudness normalisation (-14 LUFS / -1 dBTP)
# ===========================================================================

def apply_mastering_chain(
    input_wav: Path,
    output_wav: Path,
    enable_hf_repair: bool = False,
    enable_artifact_reduction: bool = False,
    eq_low_db: float = 0.0,
    eq_mid_db: float = 0.0,
    eq_high_db: float = 0.0,
    target_lufs: float = -14.0
) -> dict[str, Any]:
    """
    Non-destructive master processing chain.
    Input audio is never overwritten; output is written to output_wav.
    """
    import wave
    import numpy as np
    src = Path(input_wav).resolve()
    dst = Path(output_wav).resolve()
    if not src.exists():
        raise FileNotFoundError(f"Source file not found: {src}")

    with wave.open(str(src), "rb") as w:
        rate = w.getframerate()
        ch = w.getnchannels()
        sampwidth = w.getsampwidth()
        frames = w.readframes(w.getnframes())

    if sampwidth == 2:
        audio = np.frombuffer(frames, dtype=np.int16).astype(np.float64) / 32768.0
    else:
        audio = np.frombuffer(frames, dtype=np.float32).astype(np.float64)
    if ch == 2:
        audio = audio.reshape(-1, 2)

    # Studio-grade processing via Spotify's pedalboard (JUCE/C++ effects).
    from pedalboard import (
        Pedalboard, LowShelfFilter, PeakFilter, HighShelfFilter,
        NoiseGate, Compressor, Limiter,
    )

    # pedalboard expects float32 shaped (channels, samples).
    buf = audio.astype(np.float32)
    if buf.ndim == 1:
        buf = buf.reshape(1, -1)
    else:
        buf = buf.T  # (samples, 2) -> (2, samples)

    board = Pedalboard()

    # Step 1: Artifact reduction (opt-in) — a gentle noise gate tames low-level
    # spectral hash without ever gating musical content to silence.
    if enable_artifact_reduction:
        emit("log", component="sfx", level="info", message="Applying bounded noise gate (artifact reduction)")
        board.append(NoiseGate(threshold_db=-60.0, ratio=1.5, attack_ms=1.0, release_ms=120.0))

    # Step 2: 3-band mastering EQ (opt-in) — low shelf <250Hz, mid peak ~1kHz, high shelf >6kHz.
    if abs(eq_low_db) >= 0.1 or abs(eq_mid_db) >= 0.1 or abs(eq_high_db) >= 0.1:
        emit("log", component="eq", level="info", message="Applying 3-band mastering EQ",
             detail=f"low={eq_low_db:+.1f}dB mid={eq_mid_db:+.1f}dB high={eq_high_db:+.1f}dB")
        if abs(eq_low_db) >= 0.1:
            board.append(LowShelfFilter(cutoff_frequency_hz=250.0, gain_db=eq_low_db))
        if abs(eq_mid_db) >= 0.1:
            board.append(PeakFilter(cutoff_frequency_hz=1000.0, gain_db=eq_mid_db, q=0.7))
        if abs(eq_high_db) >= 0.1:
            board.append(HighShelfFilter(cutoff_frequency_hz=6000.0, gain_db=eq_high_db))

    # Step 3: HF air repair (opt-in) — +1.5dB shelf above 10kHz for weak MiniMax top-end.
    if enable_hf_repair:
        emit("log", component="eq", level="info", message="Applying +1.5dB high-frequency air lift (>10 kHz)")
        board.append(HighShelfFilter(cutoff_frequency_hz=10000.0, gain_db=1.5))

    # Step 4: Mastering glue — gentle bus compression + brickwall limiter the
    # hand-rolled chain lacked. Conservative so loudness normalisation stays in charge.
    board.append(Compressor(threshold_db=-18.0, ratio=2.0, attack_ms=15.0, release_ms=180.0))
    board.append(Limiter(threshold_db=-1.0, release_ms=100.0))

    if len(board) > 0:
        buf = board(buf, float(rate))

    processed = buf[0] if buf.shape[0] == 1 else buf.T  # back to (samples,) or (samples, 2)

    # Step 5: Write intermediate before loudness
    dst.parent.mkdir(parents=True, exist_ok=True)
    clipped = np.clip(processed, -1.0, 1.0)
    out_int16 = (clipped * 32767.0).astype(np.int16)
    with wave.open(str(dst), "wb") as w:
        w.setnchannels(ch)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(out_int16.tobytes())

    # Step 5: Loudness normalisation.
    # `normalize_audio_lufs` returns the *input* measurement as its 2nd value; the audio is
    # normalised to `target_lufs` by construction (gain = target - measured, applied linearly).
    _, measured_lufs, gain, pre_pk, post_pk, raw_wav = normalize_audio_lufs(dst, target_lufs=target_lufs)
    emit("log", component="loudness", level="info",
         message=f"Mastered track normalised {measured_lufs:.2f} → {target_lufs:.1f} LUFS (peak: {post_pk:.2f} dBTP)")

    return {
        "input": str(src),
        "output": str(dst),
        "rate": rate,
        "lufs": round(target_lufs, 2),
        "input_lufs": round(measured_lufs, 2),
        "gain_db": round(gain, 2),
        "peak_db": round(post_pk, 2),
        "hf_repair": enable_hf_repair,
        "artifact_reduction": enable_artifact_reduction
    }
# ===========================================================================
# Audio Format Conversion
# ===========================================================================

def _wav_to_mp3(wav_path: str, mp3_path: str, bitrate_kbps: int = 320) -> str:
    try:
        import lameenc
    except ImportError:
        raise RuntimeError("lameenc is not installed in venv")

    with wave.open(wav_path, "rb") as wf:
        n_channels = wf.getnchannels()
        sample_rate = wf.getframerate()
        pcm = wf.readframes(wf.getnframes())

    enc = lameenc.Encoder()
    enc.set_bit_rate(bitrate_kbps)
    enc.set_in_sample_rate(sample_rate)
    enc.set_channels(n_channels)
    enc.set_quality(2)
    data = enc.encode(pcm) + enc.flush()
    with open(mp3_path, "wb") as f:
        f.write(data)
    return mp3_path

def _wav_via_afconvert(wav_path: str, out_path: str, fmt_flag: str, data_flag: str) -> str:
    res = subprocess.run(
        ["/usr/bin/afconvert", "-f", fmt_flag, "-d", data_flag, wav_path, out_path],
        capture_output=True, text=True,
    )
    if res.returncode != 0:
        raise RuntimeError(f"afconvert failed: {res.stderr}")
    return out_path

def convert_audio(input_file: str, target_format: str, output_file: str | None = None) -> dict:
    src = os.path.abspath(input_file)
    if not os.path.exists(src):
        return {"error": f"Input file not found: {src}"}

    fmt = target_format.lower().strip().lstrip(".")
    if fmt not in ("mp3", "m4a", "flac", "wav"):
        return {"error": f"Unsupported format: {fmt}"}

    if output_file:
        dst = os.path.abspath(output_file)
    else:
        dst = os.path.splitext(src)[0] + f".{fmt}"

    if src == dst:
        return {"status": "ok", "format": fmt, "path": dst, "size_bytes": os.path.getsize(dst)}

    t0 = time.time()
    try:
        is_src_flac = src.lower().endswith(".flac")
        if fmt == "mp3":
            # lameenc reads via the `wave` module, which only handles 16-bit PCM.
            # FLAC and float/24-bit WAVs (e.g. plugin renders) need a PCM16 intermediate.
            needs_pcm16 = is_src_flac
            if not needs_pcm16:
                try:
                    with wave.open(src, "rb") as wf:
                        needs_pcm16 = wf.getsampwidth() != 2
                except (wave.Error, EOFError):
                    needs_pcm16 = True
            if needs_pcm16:
                tmp_wav = dst + ".tmp.wav"
                _wav_via_afconvert(src, tmp_wav, "WAVE", "LEI16")
                try:
                    _wav_to_mp3(tmp_wav, dst, bitrate_kbps=320)
                finally:
                    try: os.unlink(tmp_wav)
                    except Exception: pass
            else:
                _wav_to_mp3(src, dst, bitrate_kbps=320)
        elif fmt == "m4a":
            _wav_via_afconvert(src, dst, "m4af", "aac ")
        elif fmt == "flac":
            if is_src_flac:
                shutil.copyfile(src, dst)
            else:
                _wav_via_afconvert(src, dst, "flac", "flac")
        elif fmt == "wav":
            if is_src_flac:
                _wav_via_afconvert(src, dst, "WAVE", "LEI16")
            else:
                shutil.copyfile(src, dst)
    except Exception as e:
        return {"error": str(e)}

    elapsed = round(time.time() - t0, 3)
    size = os.path.getsize(dst)
    return {"status": "ok", "format": fmt, "path": dst, "size_bytes": size, "elapsed_sec": elapsed}

# ===========================================================================
# MiniMax Music 3 Generation Execution
# ===========================================================================

MINIMAX_WRAPPER_TEMPLATE = '''
import sys, time, json
import mlx.core as mx
import mlx_audio.music.models.minimax_music3.ar as ar
import mlx_audio.music.models.minimax_music3.euler as euler
import mlx_audio.music.models.minimax_music3.minimax_music3 as minimax_music3
import mlx_audio.music.models.minimax_music3.config as config

config.DIT_CFG_SCALE = {dit_cfg}
config.AR_CFG_SCALE = {ar_cfg}

WALL = [time.time()]
STAGE = {{}}

def stage_log(msg, component="model", level="info", detail=""):
    print(json.dumps({{"event": "log", "component": component, "level": level, "message": msg, "detail": detail}}), flush=True)

try:
    import subprocess as _sp
    _mem = int(_sp.check_output(["sysctl", "-n", "hw.memsize"]).decode().strip())
    _limit = int(_mem * 0.75)
    mx.set_wired_limit(_limit)
    stage_log(f"Wired memory limit {{_limit / (1024**3):.1f}} GB", component="power", level="info", detail=f"limit_bytes={{_limit}}")
except Exception as _e:
    stage_log(f"Could not set wired limit: {{_e}}", component="power", level="warn")

_orig_frames = ar.generate_frame_hiddens

def patched_generate_frame_hiddens(language_model, depth, config, text_ids, max_frames, seed=0):
    if "load" not in STAGE:
        STAGE["load"] = time.time() - WALL[0]
        stage_log(f"Model load + imports: {{STAGE['load']:.1f}}s", component="model", level="info", detail=f"load_sec={{STAGE['load']:.2f}}")
    stage_log("Starting GPU synthesis loop...", component="ar", level="debug")

    mx.random.seed(seed)
    key = mx.random.key(seed)
    embeddings = language_model.model.embed_tokens(text_ids)
    hidden, cache = ar.qwen3_hidden(language_model, embeddings)
    last_hidden = hidden[:, -1]
    frames = []
    t0 = time.time()

    for i in range(max_frames + 1):
        key, subkey = mx.random.split(key)
        result = ar.ar_one_frame(
            language_model, depth, config, last_hidden, cache, subkey,
            emit_frame=i > 0,
        )
        last_hidden, cache = result.last_hidden, result.cache

        if i > 0 and i % 25 == 0:
            mx.eval(result.semantic_code)
            el = time.time() - t0
            fps = i / max(el, 1e-9)
            stage_log(f"{{i}}/{{max_frames}} frames ({{fps:.1f}} f/s)", component="ar", level="debug", detail=f"fps={{fps:.1f}}")
            print(json.dumps({{"event": "progress", "component": "ar", "level": "debug", "stage": "ar", "frame": i, "max_frames": max_frames, "fps": round(fps, 1), "elapsed": round(el, 1)}}), flush=True)

        if result.ended:
            stage_log(f"EOS at frame {{i}}", component="ar", level="info", detail=f"frame={{i}}")
            break
        if i > 0:
            frames.append(result.frame_hidden)
            if len(frames) >= max_frames:
                break

    if not frames:
        raise RuntimeError("No frames generated")

    el = time.time() - t0
    STAGE["ar"] = el
    stage_log(f"Finished {{len(frames)}} frames in {{el:.1f}}s ({{len(frames) / max(el, 1e-9):.1f}} f/s avg)", component="ar", level="info", detail=f"frames={{len(frames)}} elapsed={{el:.2f}}s")
    return mx.stack(frames, axis=1)
ar.generate_frame_hiddens = patched_generate_frame_hiddens
minimax_music3.generate_frame_hiddens = patched_generate_frame_hiddens

_orig_denoise = euler.denoise_chunk
_chunks = [0]

def patched_denoise_chunk(*a, **kw):
    _chunks[0] += 1
    t0 = time.time()
    res = _orig_denoise(*a, **kw)
    mx.eval(res)
    el = time.time() - t0
    stage_log(f"Chunk {{_chunks[0]}} solved in {{el:.2f}}s", component="flow", level="debug", detail=f"chunk={{_chunks[0]}} elapsed={{el:.2f}}s")
    print(json.dumps({{"event": "progress", "component": "flow", "level": "debug", "stage": "dit", "chunk": _chunks[0], "elapsed": round(el, 2)}}), flush=True)
    return res

euler.denoise_chunk = patched_denoise_chunk
minimax_music3.denoise_chunk = patched_denoise_chunk

import mlx_audio.music.generate as gen

if __name__ == "__main__":
    try:
        gen.main()
    finally:
        total = time.time() - WALL[0]
        timings = {{"event": "timings", "total": round(total, 2), "chunks": _chunks[0]}}
        timings.update({{k: round(v, 2) for k, v in STAGE.items()}})
        print(json.dumps(timings), flush=True)
'''

def write_minimax_wrapper(guidance: float) -> Path:
    dit_cfg = float(guidance)
    ar_cfg = 1.0
    src = MINIMAX_WRAPPER_TEMPLATE.format(dit_cfg=dit_cfg, ar_cfg=ar_cfg)
    tmp_dir = Path(tempfile.gettempdir()) / "musicstudio"
    tmp_dir.mkdir(parents=True, exist_ok=True)
    path = tmp_dir / f"wrapper_{os.getpid()}_{int(guidance*100)}.py"
    path.write_text(src, encoding="utf-8")
    return path

# ===========================================================================
# Generation Orchestration
# ===========================================================================

def safe_filename_stem(title: str, max_len: int = 80) -> str:
    """Make a title safe as a macOS/ffmpeg filename stem; empty if nothing usable remains."""
    stem = re.sub(r'[\x00-\x1f/\\:*?"<>|]+', " ", title)
    stem = re.sub(r"\s+", " ", stem).strip(" .")
    return stem[:max_len].rstrip(" .")


def generate_one(
    con: sqlite3.Connection, *, model_path: str, caption: str, lyrics: str,
    duration: float, steps: int, guidance: float, seed: int,
    target_format: str, model_id: str = "", family: str = "minimax_music3",
    cot: str = "full", abc_file: str | None = None,
    prompt_id: int | None = None, job_id: int | None = None,
    index: int = 1, total: int = 1, title: str | None = None,
) -> dict:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    # Songwriter imports are named "[Title]_[Timestamp]"; everything else keeps "song_[Timestamp]".
    stamp = time.strftime("%Y%m%d_%H%M%S")
    base = safe_filename_stem(title) if title else ""
    base = f"{base}_{stamp}" if base else f"song_{stamp}"
    wav_path = OUTPUT_DIR / f"{base}.wav"
    suffix = 2
    while wav_path.exists():
        wav_path = OUTPUT_DIR / f"{base}_{suffix:02d}.wav"
        suffix += 1

    label = f"[Song {index}/{total}]" if total > 1 else f"[Song {index}]"
    emit("start", model=model_id or model_path, caption=caption, duration=duration,
         steps=steps, seed=seed, target_format=target_format,
         family=family, index=index, total=total)

    t_start = time.time()
    env = dict(os.environ)
    env["PYTHONUNBUFFERED"] = "1"
    env["TQDM_DISABLE"] = "1"

    sidecar_path: Path | None = None

    if family == "yue2":
        style_text = caption_to_style(caption)
        lyr_text = lyrics.strip() if lyrics and lyrics.strip() else "[Instrumental]"

        have_lyra = False
        try:
            import lyra
            have_lyra = True
        except ImportError:
            pass

        if have_lyra and ((Path(model_path) / "conversion.json").exists() or "vanch007" in model_id):
            vae_path = find_vae_path()
            precision = "8bit" if ("8bit" in model_id.lower() or "8bit" in str(model_path).lower()) else "bf16"
            prepare_yue2_conversion(Path(model_path))
            required_precision_file = Path(model_path) / f"ar-{precision}.safetensors"
            if not required_precision_file.is_file():
                raise RuntimeError(f"YuE2 {precision} weights are not installed")
            staging_dir = Path(tempfile.gettempdir()) / "musicstudio_yue2" / f"run_{stamp}"
            staging_dir.mkdir(parents=True, exist_ok=True)

            cmd = [
                sys.executable, "-m", "lyra.cli", "generate",
                "--model", str(model_path),
                "--vae", str(vae_path) if vae_path else "m-a-p/YuE2-Vae",
                "--precision", precision,
                "--mode", cot,
                "--style", style_text,
                "--lyrics", lyr_text,
                "--seed", str(seed),
                "--cfg-scale", str(guidance),
                "--output", str(staging_dir),
                "--offline",
            ]
            if abc_file and Path(abc_file).exists():
                cmd += ["--abc", str(abc_file)]

            emit("log", component="model", level="info", message=f"{label} [mlx-Yue] Launching generation: style='{style_text}', precision={precision}, mode={cot}, seed={seed}")

            child_tail: deque[str] = deque(maxlen=30)
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1, env=env)
            for raw_line in iter(proc.stdout.readline, ""):
                line = raw_line.strip()
                if not line:
                    continue
                child_tail.append(line)

                if "Planning score:" in line:
                    emit("progress", component="cot", level="info", stage="plan", message=line)
                elif "Generating song:" in line or "Generating audio tokens" in line:
                    emit("progress", component="ar", level="debug", stage="semantic", message=line)
                elif "Synthesizing audio:" in line:
                    m = re.search(r"(\d+)/(\d+)\s+steps", line)
                    if m:
                        cur_st = int(m.group(1))
                        tot_st = int(m.group(2))
                        emit("progress", component="nar", level="debug", stage="nar", step=cur_st, total_steps=tot_st, message=line)
                    else:
                        emit("progress", component="nar", level="debug", stage="nar", message=line)
                elif "Decoding audio:" in line:
                    emit("progress", component="vae", level="info", stage="vae", message=line)
                emit("log", component="model", level="debug", message=line)

            proc.wait()
            if proc.returncode != 0:
                error = child_process_error("YuE2", proc.returncode, child_tail)
                emit("error", component="worker", level="error", message=str(error), job_id=job_id)
                raise error

            staged_audio = staging_dir / "audio.flac"
            if not staged_audio.exists():
                staged_audio = staging_dir / "audio.wav"

            if staged_audio.exists():
                if staged_audio.suffix.lower() == ".flac":
                    _wav_via_afconvert(str(staged_audio), str(wav_path), "WAVE", "LEI16")
                else:
                    shutil.copyfile(staged_audio, wav_path)
            staged_abc = staging_dir / "score.abc"
            if staged_abc.exists():
                sidecar_dest = wav_path.with_suffix(".abc")
                shutil.copyfile(staged_abc, sidecar_dest)
                sidecar_path = sidecar_dest

            # Remove staging dir AND the engine's sibling resource-telemetry files
            shutil.rmtree(staging_dir, ignore_errors=True)
            for ext in (".resources.json", ".resources.jsonl"):
                sibling = staging_dir.parent / (staging_dir.name + ext)
                if sibling.exists():
                    try:
                        sibling.unlink()
                    except Exception:
                        pass
        else:
            yue2_script = find_yue2_engine_script()
            if not yue2_script:
                msg = "YuE2 engine (mlx-yue or generate.py) not found. Please install vanch007/mlx-Yue."
                emit("error", message=msg)
                if job_id:
                    con.execute("UPDATE jobs SET status='error', error=?, finished_at=? WHERE id=?",
                                (msg, time.time(), job_id))
                    con.commit()
                raise RuntimeError(msg)

            max_semantic_tokens = max(250, min(9000, int(duration * 25)))
            cmd = [
                sys.executable, "-u", str(yue2_script),
                "--model", model_path,
                "--style", style_text,
                "--lyrics", lyr_text,
                "--cot", cot,
                "--steps", str(steps),
                "--seed", str(seed),
                "--cfg-scale", str(guidance),
                "--max-semantic-tokens", str(max_semantic_tokens),
                "--out", str(wav_path)
            ]
            if abc_file and Path(abc_file).exists():
                cmd += ["--abc-file", str(abc_file)]

            emit("log", message=f"{label} [YuE2] Launching generation: style='{style_text}', steps={steps}, cot={cot}, tokens={max_semantic_tokens}")

            child_tail = deque(maxlen=30)
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1, env=env)
            for raw_line in iter(proc.stdout.readline, ""):
                line = raw_line.strip()
                if not line:
                    continue
                child_tail.append(line)
                if "[plan]" in line:
                    emit("progress", component="cot", level="info", stage="plan", message=line)
                elif "[semantic]" in line:
                    emit("progress", component="ar", level="debug", stage="semantic", message=line)
                elif "[nar]" in line and "step" in line:
                    m = re.search(r"step\s+(\d+)/(\d+)", line)
                    if m:
                        emit("progress", component="nar", level="debug", stage="nar", step=int(m.group(1)), total_steps=int(m.group(2)), message=line)
                    else:
                        emit("progress", component="nar", level="debug", stage="nar", message=line)
                elif "[vae]" in line:
                    emit("progress", component="vae", level="info", stage="vae", message=line)
                else:
                    emit("log", component="model", level="debug", message=line)

            proc.wait()
            if proc.returncode != 0:
                error = child_process_error("YuE2", proc.returncode, child_tail)
                emit("error", component="worker", level="error", message=str(error), job_id=job_id)
                raise error

            possible_abc = wav_path.with_suffix(".abc")
            if possible_abc.exists():
                sidecar_path = possible_abc

    else:
        # MiniMax Music 3 (FR-007 Token Safety & Budget Check)
        initial_tokens, count_method = count_prompt_tokens(caption, lyrics or "[instrumental]", model_path)
        if initial_tokens > DEFAULT_PROMPT_TOKEN_BUDGET:
            caption, lyrics, final_tokens, dropped, count_method = trim_prompt_for_budget(
                caption, lyrics, DEFAULT_PROMPT_TOKEN_BUDGET, model_path
            )
            emit("log", component="tokenizer", level="warn",
                 message=f"Prompt exceeded budget ({initial_tokens} tokens > {DEFAULT_PROMPT_TOKEN_BUDGET}). Auto-trimmed {dropped} lyric line(s) to {final_tokens} tokens.",
                 detail=f"method={count_method} dropped_lines={dropped} initial={initial_tokens} final={final_tokens}")
        else:
            emit("log", component="tokenizer", level="info",
                 message=f"Prompt tokens: {initial_tokens}/{DEFAULT_PROMPT_TOKEN_BUDGET} ({count_method})",
                 detail=f"method={count_method} remaining={DEFAULT_PROMPT_TOKEN_BUDGET - initial_tokens}")

        wrapper = write_minimax_wrapper(guidance)
        cmd = [
            sys.executable, "-u", str(wrapper),
            "--model", model_path,
            "--caption", caption,
            "--lyrics", lyrics or "[instrumental]",
            "--steps", str(steps),
            "--seed", str(seed),
            "--output", str(wav_path),
        ]
        if duration:
            cmd += ["--duration", str(duration)]

        emit("log", component="model", level="info", message=f"{label} [MiniMax] Launching MLX generation: duration={duration}s, steps={steps}, guidance={guidance}")

        child_tail = deque(maxlen=30)
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1, env=env)
        for raw_line in iter(proc.stdout.readline, ""):
            line = raw_line.strip()
            if not line:
                continue
            child_tail.append(line)
            if line.startswith('{"event"'):
                print(line, flush=True)
            else:
                emit("log", component="model", level="debug", message=line)
        proc.wait()

        if proc.returncode != 0:
            error = child_process_error("MiniMax", proc.returncode, child_tail)
            emit("error", component="worker", level="error", message=str(error), job_id=job_id)
            raise error

    elapsed = round(time.time() - t_start, 2)
    final_output = str(wav_path)

    # FR-009 Loudness Normalisation (-14 LUFS / -1 dBTP)
    lufs_info = {}
    if wav_path.exists():
        try:
            _, lufs_val, gain_val, pre_pk, post_pk, raw_wav = normalize_audio_lufs(wav_path)
            lufs_info = {
                "lufs": round(lufs_val, 2),
                "gain_db": round(gain_val, 2),
                "pre_peak_db": round(pre_pk, 2),
                "post_peak_db": round(post_pk, 2),
                "raw_file": str(raw_wav)
            }
        except Exception as e:
            emit("log", component="loudness", level="warn", message=f"Loudness normalisation skipped: {e}")

    # Full-track analysis on the normalised WAV (still present before conversion).
    analysis = {}
    if wav_path.exists():
        analysis = analyze_audio(wav_path, lufs_info)

    # Format Conversion
    if target_format.lower() != "wav" and wav_path.exists():
        emit("log", component="convert", level="info", message=f"[Convert] Converting WAV to {target_format.upper()}...")
        target = wav_path.with_suffix(f".{target_format.lower()}")
        conv = convert_audio(str(wav_path), target_format, str(target))
        if "error" not in conv and Path(conv["path"]).exists():
            final_output = conv["path"]
            emit("log", component="convert", level="info", message=f"[Convert] Successfully created {target_format.upper()} ({final_output})")
            try:
                wav_path.unlink()
            except Exception:
                pass
        else:
            emit("log", component="convert", level="warn", message=f"Conversion failed: {conv.get('error')}; keeping WAV")

    # Write native tags (ID3 / MP4 / Vorbis / RIFF) into the delivered file.
    prow = None
    if prompt_id:
        try:
            prow = con.execute(
                "SELECT title, genre, subgenre, bpm, music_key, scale, vocal, pro_tip, "
                "time_signature FROM prompts WHERE id = ?", (prompt_id,)
            ).fetchone()
        except Exception:
            prow = None
    # Album groups a batch, not a genre, so players don't collapse every track of a
    # genre into one incoherent album.
    batch_name = ""
    if job_id:
        try:
            jrow = con.execute("SELECT batch_id FROM jobs WHERE id = ?", (job_id,)).fetchone()
            if jrow and jrow["batch_id"]:
                batch_name = f"MusicStudio Batch {jrow['batch_id']}"
        except Exception:
            batch_name = ""
    if not batch_name:
        batch_name = f"MusicStudio Generations {time.strftime('%Y-%m')}"

    target_bpm = (prow["bpm"] if prow else None)
    target_key = (prow["music_key"] if prow else "")
    target_scale = (prow["scale"] if prow else "")
    measured_bpm = analysis.get("bpm")

    # Defeat librosa half/double-tempo octave errors: if the measurement is ~2x or ~0.5x
    # the prompt's intended tempo, snap to the ground truth.
    final_bpm = measured_bpm
    if measured_bpm and target_bpm:
        tb = float(target_bpm)
        if abs(measured_bpm - 2 * tb) < 3 or abs(measured_bpm - 0.5 * tb) < 3:
            emit("log", component="analysis", level="info",
                 message=f"Snapped octave-error BPM {measured_bpm} -> intended {tb}")
            final_bpm = tb
    if not final_bpm:
        final_bpm = target_bpm

    gen_group = {
        "model": model_id or model_path, "seed": seed, "steps": steps,
        "guidance": guidance, "duration": duration,
        "vocal": (prow["vocal"] if prow else ""),
        "time_signature": (prow["time_signature"] if prow else ""),
    }
    target_group = {"target_bpm": target_bpm,
                    "target_key": _tkey_grammar(target_key, target_scale) or target_key}
    dsp_group = {k: analysis[k] for k in (
        "camelot", "beat_count", "onset_rate_hz", "mood_descriptor",
        "spectral_centroid_hz", "spectral_rolloff_hz", "zero_crossing_rate",
        "rms_energy", "key", "scale") if analysis.get(k) not in (None, "")}
    norm_group = {k: analysis[k] for k in (
        "lufs", "lra_lu", "gain_db", "pre_peak_db", "post_peak_db")
        if analysis.get(k) not in (None, "")}

    tag_meta = {
        "title": (prow["title"] if prow else "") or f"MusicStudio {time.strftime('%Y-%m-%d')}",
        "artist": "MusicStudio",
        "album_artist": "MusicStudio",
        "album": batch_name,
        "genre": (prow["subgenre"] or prow["genre"]) if prow else "",
        "composer": model_id or model_path,
        "comment": "\n\n".join(x for x in (caption, (prow["pro_tip"] if prow else "")) if x),
        "lyrics": lyrics,
        "bpm": final_bpm,
        "key": analysis.get("key") or target_key,
        "scale": analysis.get("scale") or target_scale,
        "duration_ms": analysis.get("duration_ms"),
        "gen": gen_group, "target": target_group, "dsp": dsp_group, "norm": norm_group,
    }
    if os.path.exists(final_output):
        tag_audio_file(final_output, tag_meta)

    size_mb = round(os.path.getsize(final_output) / (1024 * 1024), 2) if os.path.exists(final_output) else 0.0

    # The final audio, generation row, and job completion form one irreversible boundary.
    cur = con.cursor()
    timings_json = json.dumps(lufs_info)
    analysis_json = json.dumps(analysis) if analysis else None
    cur.execute(
        """INSERT INTO generations (job_id, prompt_id, model_id, caption, lyrics,
                                   seed, duration, steps, format, output_file,
                                   sidecar_file, size_mb, elapsed_sec, timings,
                                   analysis, analyzed_at, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (job_id, prompt_id, model_id or model_path, caption, lyrics,
         seed, duration, steps, target_format, final_output,
         str(sidecar_path) if sidecar_path else None, size_mb, elapsed, timings_json,
         analysis_json,
         (os.path.getmtime(final_output) if os.path.exists(final_output) else time.time()),
         time.time()),
    )
    gen_id = cur.lastrowid
    if job_id:
        con.execute(
            "UPDATE jobs SET status='done', progress=1.0, output_file=?, finished_at=? WHERE id=?",
            (final_output, time.time(), job_id),
        )
    con.commit()
    emit("log", component="db", level="info", message=f"Generation #{gen_id} recorded in database", detail=f"id={gen_id} format={target_format} size_mb={size_mb:.2f} elapsed={elapsed:.1f}s")
    item = {
        "id": str(gen_id),
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
        "model": model_id or model_path,
        "caption": caption,
        "lyrics": lyrics,
        "duration": duration,
        "steps": steps,
        "guidance": guidance,
        "seed": seed,
        "output_file": final_output,
        "sidecar_file": str(sidecar_path) if sidecar_path else None,
        "format": target_format,
        "size_mb": size_mb,
        "elapsed_sec": elapsed,
    }
    emit("complete", component="worker", level="info", output_file=final_output, format=target_format,
         size_mb=size_mb, elapsed_sec=elapsed, seed=seed,
         sidecar_file=str(sidecar_path) if sidecar_path else None,
         index=index, total=total, item=item)
    return item

# ===========================================================================
# CLI Commands
# ===========================================================================

def resolve_model(con: sqlite3.Connection, model_ref: str) -> tuple[str, str, str]:
    """Resolve model reference to (weights_path, model_id, family)."""
    # Try exact match on ID
    row = con.execute("SELECT id, weights_path, family, available, unavailable_reason FROM models WHERE id = ?", (model_ref,)).fetchone()
    if not row:
        # Try weights_path match
        row = con.execute("SELECT id, weights_path, family, available, unavailable_reason FROM models WHERE weights_path LIKE ?", (f"%{model_ref}%",)).fetchone()
    if not row:
        # Try name match
        row = con.execute("SELECT id, weights_path, family, available, unavailable_reason FROM models WHERE name LIKE ?", (f"%{model_ref}%",)).fetchone()

    if row:
        wpath = row["weights_path"]
        # If relative, verify if found on disk
        if not os.path.isabs(wpath):
            found = find_weights_path(wpath)
            if found:
                wpath = str(found.resolve())
        return wpath, row["id"], row["family"]

    # Fallback to direct path or default
    p = Path(model_ref)
    if p.exists():
        fam = "yue2" if "yue2" in model_ref.lower() else "minimax_music3"
        return str(p.resolve()), model_ref, fam

    raise ValueError(f"Model '{model_ref}' not found in database or disk")

def cmd_init(args: argparse.Namespace) -> int:
    con = connect(args.db)
    con.executescript(SCHEMA_SQL)
    seed_models(con)
    apply_migrations(con, Path(args.db).resolve(), CURRENT_SCHEMA_VERSION)
    print(f"Database initialized at {args.db}")
    return 0

def cmd_schema(args: argparse.Namespace) -> int:
    con = connect(args.db)
    db_file = Path(args.db).resolve()
    cur_ver = get_schema_version(con)

    if args.backup:
        bak = backup_database(db_file, cur_ver)
        print(f"Backup created: {bak} ({bak.stat().st_size / (1024*1024):.2f} MB)")
        return 0

    if args.status:
        pending = [v for v in range(cur_ver, CURRENT_SCHEMA_VERSION) if v in MIGRATIONS]
        print(f"Database:           {db_file}")
        print(f"Current version:    {cur_ver}")
        print(f"Target version:     {CURRENT_SCHEMA_VERSION}")
        print(f"Pending migrations: {len(pending)}")
        for p in pending:
            fn = MIGRATIONS[p]
            print(f"  v{p} -> v{p+1}: {fn.__name__} - {fn.__doc__ or 'No description'}")
        return 0

    if args.migrate:
        print(f"Migrating schema from v{cur_ver} to v{CURRENT_SCHEMA_VERSION}...")
        final_ver = apply_migrations(con, db_file, CURRENT_SCHEMA_VERSION)
        print(f"Schema migrated to v{final_ver}")
        return 0

    args.status = True
    return cmd_schema(args)

def cmd_render(args: argparse.Namespace) -> int:
    con = connect(args.db)
    slug = args.prompt_slug
    row = con.execute("SELECT id, title FROM prompts WHERE slug = ?", (slug,)).fetchone()
    if not row:
        print(f"Error: Prompt '{slug}' not found in database", file=sys.stderr)
        return 1

    rendered = render_for_model(con, row["id"], args.model)
    print(f"Prompt: {row['title']} (slug: {slug})")
    print(f"Model:  {args.model}")
    print("-" * 60)
    print(rendered)
    print("-" * 60)
    print(f"Length: {len(rendered)} chars, {len(rendered.split())} words")
    return 0
def cmd_estimate(args: argparse.Namespace) -> int:
    res = calculate_phase_eta(
        model_id=args.model,
        duration=float(args.duration),
        steps=int(args.steps or (30 if "minimax" in args.model else 32)),
        cot=args.cot
    )
    print(json.dumps(res, indent=2))
    return 0

def cmd_models(args: argparse.Namespace) -> int:
    con = connect(args.db)
    seed_models(con)
    rows = con.execute("SELECT id, name, family, backend, available, unavailable_reason, weights_path FROM models ORDER BY sort_order ASC").fetchall()
    print(f"{'STATUS':<6} {'ID':<35} {'FAMILY':<15} {'PATH'}")
    print("-" * 80)
    for r in rows:
        st = "OK" if r["available"] else "MISS"
        reason = f" ({r['unavailable_reason']})" if not r["available"] and r["unavailable_reason"] else ""
        print(f"{st:<6} {r['id']:<35} {r['family']:<15} {r['weights_path']}{reason}")
    return 0

def cmd_stats(args: argparse.Namespace) -> int:
    con = connect(args.db)
    prompts_n = con.execute("SELECT count(*) FROM prompts").fetchone()[0]
    segments_n = con.execute("SELECT count(*) FROM prompt_segments").fetchone()[0]
    keywords_n = con.execute("SELECT count(*) FROM keywords").fetchone()[0]
    generations_n = con.execute("SELECT count(*) FROM generations").fetchone()[0]
    jobs_n = con.execute("SELECT count(*) FROM jobs").fetchone()[0]
    models_avail = con.execute("SELECT count(*) FROM models WHERE available = 1").fetchone()[0]
    models_tot = con.execute("SELECT count(*) FROM models").fetchone()[0]
    print(f"Prompts:     {prompts_n}")
    print(f"Segments:    {segments_n}")
    print(f"Keywords:    {keywords_n}")
    print(f"Models:      {models_avail}/{models_tot} available")
    print(f"Generations: {generations_n}")
    print(f"Jobs:        {jobs_n}")
    return 0

def cmd_tokens(args: argparse.Namespace) -> int:
    con = connect(args.db)
    caption = args.caption or ""
    lyrics = args.lyrics or ""

    if args.prompt_slug:
        row = con.execute("SELECT id, title, genre FROM prompts WHERE slug = ?", (args.prompt_slug,)).fetchone()
        if row:
            caption = render_for_model(con, row["id"], "minimax_music3:MiniMax-Music3-mxfp8")

    tokens, method = count_prompt_tokens(caption, lyrics)
    budget = DEFAULT_PROMPT_TOKEN_BUDGET
    limit = MINIMAX_MAX_PROMPT_TOKENS
    will_trim = tokens > budget

    res = {
        "tokens": tokens,
        "method": method,
        "budget": budget,
        "limit": limit,
        "remaining": max(0, budget - tokens),
        "will_trim": will_trim,
        "caption_chars": len(caption),
        "lyrics_chars": len(lyrics)
    }

    if will_trim:
        cap, trimmed_lyr, final_toks, dropped, meth = trim_prompt_for_budget(caption, lyrics, budget)
        res["trimmed_tokens"] = final_toks
        res["dropped_lines"] = dropped
        res["trimmed_lyrics"] = trimmed_lyr

    print(json.dumps(res, indent=2))
    return 0

def cmd_loudness(args: argparse.Namespace) -> int:
    p = Path(args.input).resolve()
    if not p.exists():
        print(f"Error: File not found: {p}", file=sys.stderr)
        return 1
    norm_path, meas_lufs, gain_db, pre_pk, post_pk, raw_path = normalize_audio_lufs(p, args.target_lufs, args.target_peak)
    print(f"Input:         {p.name}")
    print(f"Original LUFS: {meas_lufs:.2f} LUFS (peak: {pre_pk:.2f} dBTP)")
    print(f"Applied Gain:  {gain_db:+.2f} dB")
    print(f"Normalised:    {norm_path.name}")
    print(f"Target LUFS:   {args.target_lufs:.2f} LUFS")
    print(f"Output Peak:   {post_pk:.2f} dBTP")
    print(f"Backup raw:    {raw_path.name}")
    return 0

def _evaluation_payload(row: sqlite3.Row | dict) -> dict:
    return {
        "generationId": int(row["generation_id"]),
        "status": row["status"],
        "melody": row["melody"],
        "arrangement": row["arrangement"],
        "musicality": row["musicality"],
        "vocal": row["vocal"],
        "instrumental": row["instrumental"],
        "mixing": row["mixing"],
        "structure": row["structure"],
        "overall": row["overall"],
        "device": row["device"],
        "evaluatorVersion": row["evaluator_version"],
        "elapsedSec": row["elapsed_sec"],
        "error": row["error"],
        "createdAt": row["created_at"],
        "updatedAt": row["updated_at"],
    }


def run_songbench_evaluation(con: sqlite3.Connection, generation_id: int, audio_path: Path) -> bool:
    """Install if needed, score one committed generation, and isolate all failures."""
    from songbench import artifact_status, ensure_evaluator, evaluate_song
    from songbench.convert import EVALUATOR_VERSION

    audio_path = Path(audio_path).expanduser().resolve()
    state = artifact_status(MODELS_DIR)
    initial_status = "evaluating" if state["status"] == "ready" else "installing"
    now = time.time()
    con.execute(
        """INSERT INTO songbench_evaluations
               (generation_id, status, evaluator_version, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?)
           ON CONFLICT(generation_id) DO UPDATE SET
               status=excluded.status, error=NULL, updated_at=excluded.updated_at""",
        (generation_id, initial_status, EVALUATOR_VERSION, now, now),
    )
    con.commit()

    try:
        if initial_status == "installing":
            emit("eval_install_start", component="eval", level="info",
                 generation_id=generation_id, stage="starting", fraction=0.0)

        def progress(update: dict[str, object]) -> None:
            emit("eval_install_progress", component="eval", level="info",
                 generation_id=generation_id, **update)

        ensure_evaluator(MODELS_DIR, progress)
        con.execute(
            "UPDATE songbench_evaluations SET status='evaluating', error=NULL, updated_at=? WHERE generation_id=?",
            (time.time(), generation_id),
        )
        con.commit()
        emit("eval_start", component="eval", level="info", generation_id=generation_id)
        result = evaluate_song(audio_path, MODELS_DIR)
        finished = time.time()
        con.execute(
            """UPDATE songbench_evaluations SET
                   status='completed', melody=?, arrangement=?, musicality=?, vocal=?,
                   instrumental=?, mixing=?, structure=?, overall=?, device=?,
                   evaluator_version=?, elapsed_sec=?, error=NULL, updated_at=?
               WHERE generation_id=?""",
            (result["Melody"], result["Arrangement"], result["Musicality"], result["Vocal"],
             result["Instrumental"], result["Mixing"], result["Structure"], result["overall"],
             result["device"], result["evaluator_version"], result["elapsed_sec"], finished,
             generation_id),
        )
        con.commit()
        # Additive re-tag: write SongBench scores into the already-tagged file so the
        # scores travel with the audio. Only the sb group is touched.
        try:
            tag_audio_file(audio_path, {"sb": {
                "score_overall": round(float(result["overall"]), 3),
                "melody": round(float(result["Melody"]), 3),
                "arrangement": round(float(result["Arrangement"]), 3),
                "musicality": round(float(result["Musicality"]), 3),
                "vocal": round(float(result["Vocal"]), 3),
                "instrumental": round(float(result["Instrumental"]), 3),
                "mixing": round(float(result["Mixing"]), 3),
                "structure": round(float(result["Structure"]), 3),
                "evaluator_version": result["evaluator_version"],
            }})
        except Exception as tag_err:
            emit("log", component="tag", level="warn",
                 message=f"SongBench re-tag failed: {tag_err}")
        row = con.execute(
            "SELECT * FROM songbench_evaluations WHERE generation_id=?", (generation_id,)
        ).fetchone()
        emit("eval_complete", component="eval", level="info", generation_id=generation_id,
             evaluation=_evaluation_payload(row))
        return True
    except Exception as error:
        message = (str(error).strip() or "SongBench evaluation failed")[:240]
        failed = time.time()
        con.execute(
            """INSERT INTO songbench_evaluations
                   (generation_id, status, evaluator_version, error, created_at, updated_at)
               VALUES (?, 'failed', ?, ?, ?, ?)
               ON CONFLICT(generation_id) DO UPDATE SET
                   status='failed', error=excluded.error, updated_at=excluded.updated_at""",
            (generation_id, EVALUATOR_VERSION, message, failed, failed),
        )
        con.commit()
        emit("eval_failed", component="eval", level="warn", generation_id=generation_id,
             error=message, message=message)
        return False


def cmd_songbench(args: argparse.Namespace) -> int:
    con = connect(args.db)
    apply_migrations(con, Path(args.db).resolve(), CURRENT_SCHEMA_VERSION)
    row = con.execute(
        "SELECT id, output_file FROM generations WHERE id=?", (args.generation_id,)
    ).fetchone()
    audio_path = Path(args.audio_path).expanduser().resolve()
    if row is None:
        emit("eval_failed", component="eval", level="warn", generation_id=args.generation_id,
             error="Generation not found", message="Generation not found")
        return 2
    recorded_path = Path(row["output_file"]).expanduser().resolve()
    if audio_path != recorded_path:
        emit("eval_failed", component="eval", level="warn", generation_id=args.generation_id,
             error="Audio path does not match generation", message="Audio path does not match generation")
        return 2
    if not audio_path.is_file():
        emit("eval_failed", component="eval", level="warn", generation_id=args.generation_id,
             error="Audio file is missing", message="Audio file is missing")
        return 2
    return 0 if run_songbench_evaluation(con, int(row["id"]), audio_path) else 1


def report_songwriter_generation(con: sqlite3.Connection, generation_id: int) -> bool:
    """POST one metadata-only completion; retain failure for the next worker start."""
    row = con.execute(
        """SELECT g.*, j.params, e.status AS eval_status, e.melody, e.arrangement,
                  e.musicality, e.vocal, e.instrumental, e.mixing, e.structure,
                  e.overall, e.device, e.evaluator_version, e.elapsed_sec AS eval_elapsed,
                  e.error AS eval_error
           FROM generations g
           LEFT JOIN jobs j ON j.id = g.job_id
           LEFT JOIN songbench_evaluations e ON e.generation_id = g.id
           WHERE g.id=?""",
        (generation_id,),
    ).fetchone()
    if row is None or not row["songwriter_id"]:
        return True

    evaluation: dict[str, object]
    if row["eval_status"] == "completed":
        evaluation = {
            "status": "completed",
            "evaluator_version": row["evaluator_version"],
            "device": row["device"],
            "elapsed_sec": row["eval_elapsed"],
            "scores": {
                "melody": row["melody"], "arrangement": row["arrangement"],
                "musicality": row["musicality"], "vocal": row["vocal"],
                "instrumental": row["instrumental"], "mixing": row["mixing"],
                "structure": row["structure"],
            },
            "overall": row["overall"],
        }
    else:
        evaluation = {
            "status": "failed",
            "evaluator_version": row["evaluator_version"] or "songbench-reference-cpu-v1",
            "elapsed_sec": row["eval_elapsed"] or 0.0,
            "error": (row["eval_error"] or "SongBench evaluation failed")[:240],
            "retryable": True,
        }

    params = json.loads(row["params"] or "{}")
    payload = {
        "source": {"song_id": row["songwriter_id"], "song_revision": row["songwriter_revision"]},
        "client": {
            "generation_id": str(row["id"]),
            "generation_uuid": row["songwriter_generation_uuid"],
            "app_version": "2.0",
        },
        "status": "completed",
        "completed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(row["created_at"])),
        "generation": {
            "model_id": row["model_id"],
            "model_family": "yue2" if "yue" in row["model_id"].lower() else "minimax_music3",
            "seed": row["seed"],
            "duration_requested_sec": row["duration"],
            "duration_actual_sec": row["duration"],
            "steps": row["steps"],
            "guidance": row["guidance"],
            "cot_mode": params.get("cot") if "yue" in row["model_id"].lower() else None,
            "output_format": row["format"],
            "elapsed_sec": row["elapsed_sec"],
        },
        "evaluation": evaluation,
    }
    base = os.environ.get("SONGWRITER_API_URL", "http://127.0.0.1:8000").rstrip("/")
    token = os.environ.get("SONGWRITER_API_TOKEN", "musicstudio")
    url = f"{base}/v1/songs/{row['songwriter_id']}/generations"
    request = urllib.request.Request(
        url,
        data=json.dumps(payload, separators=(",", ":")).encode("utf-8"),
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Idempotency-Key": row["songwriter_generation_uuid"],
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            result = json.loads(response.read().decode("utf-8"))
        con.execute(
            """UPDATE generations SET songwriter_report_status='completed',
                      songwriter_remote_generation_id=?, songwriter_report_error=NULL
               WHERE id=?""",
            (result.get("generation_id"), generation_id),
        )
        con.commit()
        emit("log", component="worker", level="info", message="Reported generation to Songwriter",
             detail=f"song={row['songwriter_id']} generation={generation_id}")
        return True
    except Exception as error:
        message = (str(error).strip() or "Songwriter report failed")[:240]
        con.execute(
            "UPDATE generations SET songwriter_report_status='failed', songwriter_report_error=? WHERE id=?",
            (message, generation_id),
        )
        con.commit()
        emit("log", component="worker", level="warn", message="Songwriter report deferred", detail=message)
        return False


def retry_songwriter_reports(con: sqlite3.Connection) -> None:
    rows = con.execute(
        """SELECT id FROM generations
           WHERE songwriter_id IS NOT NULL AND songwriter_report_status='failed'
           ORDER BY created_at LIMIT 20"""
    ).fetchall()
    for row in rows:
        report_songwriter_generation(con, int(row["id"]))


def cmd_generate(args: argparse.Namespace) -> int:
    global OUTPUT_DIR
    if args.output_dir:
        OUTPUT_DIR = Path(args.output_dir).resolve()

    con = connect(args.db)
    seed_models(con)

    wpath, mid, fam = resolve_model(con, args.model)
    guidance = args.guidance if args.guidance is not None else (args.cfg_scale if args.cfg_scale is not None else (1.7 if fam == "minimax_music3" else 1.0))

    caption = args.caption or (args.style or "Indie pop acoustic")
    generate_one(
        con,
        model_path=wpath,
        caption=caption,
        lyrics=args.lyrics or "",
        duration=args.duration,
        steps=args.steps or (30 if fam == "minimax_music3" else 32),
        guidance=guidance,
        seed=args.seed if args.seed is not None else secrets.randbelow(1_000_000_000),
        target_format=args.format,
        model_id=mid,
        family=fam,
        cot=args.cot,
        abc_file=args.abc_file,
    )
    return 0

def cmd_worker(args: argparse.Namespace) -> int:
    global OUTPUT_DIR
    if args.output_dir:
        OUTPUT_DIR = Path(args.output_dir).resolve()

    con = connect(args.db)
    apply_migrations(con, Path(args.db).resolve(), CURRENT_SCHEMA_VERSION)
    seed_models(con)
    retry_songwriter_reports(con)
    interrupted = con.execute(
        """UPDATE songbench_evaluations
           SET status='failed', error='Evaluation interrupted; retry available', updated_at=?
           WHERE status IN ('installing','evaluating')""",
        (time.time(),),
    ).rowcount
    # A freshly started worker means nothing is actually running. Any job left in
    # 'running' is orphaned by a worker that died mid-job; requeue it so it retries
    # instead of wedging the queue (the UI cannot clear a 'running' row).
    reclaimed = con.execute(
        "UPDATE jobs SET status='queued', started_at=NULL WHERE status='running'"
    ).rowcount
    con.commit()
    if reclaimed:
        emit("log", component="worker", level="info",
             message=f"Requeued {reclaimed} orphaned running job(s)")
    if interrupted:
        emit("log", component="eval", level="warn",
             message=f"Marked {interrupted} interrupted evaluation(s) retryable")
    idle_since = None
    done = 0

    emit("log", component="worker", level="info", message="Starting job queue consumer")

    while True:
        row = con.execute(
            "SELECT * FROM jobs WHERE status='queued' ORDER BY position ASC, id ASC LIMIT 1"
        ).fetchone()

        if not row:
            if idle_since is None:
                idle_since = time.time()
                emit("queue_idle", component="queue", level="debug", processed=done)
            elif time.time() - idle_since >= 1.0:
                emit("log", component="worker", level="info", message="Queue drained; worker exiting")
                return 0
            time.sleep(0.25)
            continue

        idle_since = None
        emit("log", component="worker", level="info", message=f"Claimed job #{row['id']}", detail=f"seed={row['seed']} model={row['model_id']}")
        con.execute("UPDATE jobs SET status='running', started_at=? WHERE id=?",
                    (time.time(), row["id"]))
        con.commit()

        params = json.loads(row["params"] or "{}")
        try:
            wpath, mid, fam = resolve_model(con, row["model_id"])
            item = generate_one(
                con,
                model_path=wpath,
                caption=row["caption"],
                lyrics=row["lyrics"] or "",
                duration=float(params.get("duration", 60.0)),
                steps=int(params.get("steps", 30 if fam == "minimax_music3" else 32)),
                guidance=float(params.get("guidance", 1.7 if fam == "minimax_music3" else 1.0)),
                seed=int(row["seed"] or 0),
                target_format=str(params.get("format", "mp3")),
                model_id=mid,
                family=fam,
                cot=str(params.get("cot", "full")),
                abc_file=params.get("abc_file"),
                prompt_id=row["prompt_id"],
                job_id=row["id"],
                index=done + 1,
                total=1,
                title=params.get("songwriter_title"),
            )
            songwriter_id = params.get("songwriter_id")
            if songwriter_id:
                con.execute(
                    """UPDATE generations SET songwriter_id=?, songwriter_revision=?,
                              songwriter_generation_uuid=?, songwriter_report_status='pending'
                       WHERE id=?""",
                    (songwriter_id, params.get("songwriter_revision"),
                     str(uuid.uuid4()), int(item["id"])),
                )
                con.commit()
            run_songbench_evaluation(con, int(item["id"]), Path(item["output_file"]))
            report_songwriter_generation(con, int(item["id"]))
            done += 1
        except Exception as e:
            con.execute("UPDATE jobs SET status='error', error=?, finished_at=? WHERE id=?",
                        (str(e), time.time(), row["id"]))
            con.commit()
            emit("error", message=f"Job {row['id']} failed: {e}")

    return 0

def cmd_convert(args: argparse.Namespace) -> int:
    # --tags-from lets an export (e.g. a plugin render in a temp WAV) inherit the
    # original track's metadata instead of the untagged intermediate's.
    src_tags = read_audio_tags(args.tags_from or args.input)
    res = convert_audio(args.input, args.format, args.output)
    if "error" not in res and src_tags and os.path.exists(res.get("path", "")):
        tag_audio_file(res["path"], src_tags)
    print(json.dumps(res))
    return 0 if "error" not in res else 1

def cmd_tags(args: argparse.Namespace) -> int:
    """Read tags as JSON, or write tags from a JSON blob (two-way DB<->file sync)."""
    path = Path(args.input).expanduser().resolve()
    if not path.exists():
        print(json.dumps({"error": f"File not found: {path}"}))
        return 1
    if args.write:
        try:
            meta = json.loads(args.write)
        except json.JSONDecodeError as e:
            print(json.dumps({"error": f"Invalid --write JSON: {e}"}))
            return 1
        ok = tag_audio_file(path, meta)
        print(json.dumps({"status": "ok" if ok else "failed", "path": str(path)}))
        return 0 if ok else 1
    tags = read_audio_tags(path)
    tags["path"] = str(path)
    tags["mtime"] = os.path.getmtime(path)
    print(json.dumps(tags, default=str))
    return 0


def cmd_reconcile(args: argparse.Namespace) -> int:
    """Reconcile DB <-> file: re-read tags+analysis for rows whose file is newer than
    analyzed_at (or never analyzed). File tags win on conflict. Backfills pre-existing
    files. Prints a JSON summary."""
    con = connect(args.db)
    apply_migrations(con, Path(args.db).resolve(), CURRENT_SCHEMA_VERSION)
    rows = con.execute(
        "SELECT id, output_file, analyzed_at FROM generations ORDER BY created_at DESC"
    ).fetchall()
    updated = 0
    missing = 0
    for row in rows:
        out = row["output_file"]
        if not out or not os.path.exists(out):
            missing += 1
            continue
        mtime = os.path.getmtime(out)
        analyzed_at = row["analyzed_at"]
        if analyzed_at is not None and mtime <= analyzed_at + 1e-6:
            continue   # DB already current with the file
        tags = read_audio_tags(out)
        if not tags:
            # No tags to merge; still mark reconciled so we don't re-scan each time.
            con.execute("UPDATE generations SET analyzed_at=? WHERE id=?", (mtime, row["id"]))
            updated += 1
            continue
        # Flatten groups into one analysis dict (dsp/norm/sb/gen/target already nested).
        con.execute(
            "UPDATE generations SET analysis=?, analyzed_at=? WHERE id=?",
            (json.dumps(tags, default=str), mtime, row["id"]),
        )
        updated += 1
    con.commit()
    print(json.dumps({"status": "ok", "scanned": len(rows), "updated": updated, "missing": missing}))
    return 0


def render_spectrogram(audio_path: Path, out_png: Path, *, width: int = 900, height: int = 320) -> Path:
    """Render a mel-spectrogram PNG (librosa -> matplotlib Agg). Headless, cached by caller."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import librosa, librosa.display
    import numpy as np

    y, sr = librosa.load(str(audio_path), sr=22050, mono=True)
    mel = librosa.feature.melspectrogram(y=y, sr=sr, n_mels=128, fmax=sr // 2)
    mel_db = librosa.power_to_db(mel, ref=np.max)

    dpi = 100
    fig, ax = plt.subplots(figsize=(width / dpi, height / dpi), dpi=dpi)
    librosa.display.specshow(mel_db, sr=sr, x_axis="time", y_axis="mel",
                             fmax=sr // 2, ax=ax, cmap="magma")
    ax.set_facecolor("#1a1b26")
    fig.patch.set_facecolor("#1a1b26")
    for spine in ax.spines.values():
        spine.set_color("#565f89")
    ax.tick_params(colors="#a9b1d6", labelsize=7)
    ax.xaxis.label.set_color("#a9b1d6"); ax.yaxis.label.set_color("#a9b1d6")
    ax.xaxis.label.set_size(8); ax.yaxis.label.set_size(8)
    fig.tight_layout(pad=0.4)
    out_png.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(str(out_png), facecolor=fig.get_facecolor())
    plt.close(fig)
    return out_png


def cmd_spectrogram(args: argparse.Namespace) -> int:
    """Render (and cache) a mel-spectrogram PNG next to the audio; print its path as JSON."""
    path = Path(args.input).expanduser().resolve()
    if not path.exists():
        print(json.dumps({"error": f"File not found: {path}"}))
        return 1
    out_png = Path(args.output).expanduser().resolve() if args.output else \
        path.with_name(f".{path.stem}.spectrogram.png")
    # Cache: reuse unless the audio is newer than the PNG.
    if out_png.exists() and not args.force and \
            os.path.getmtime(out_png) >= os.path.getmtime(path):
        print(json.dumps({"status": "cached", "path": str(out_png)}))
        return 0
    try:
        render_spectrogram(path, out_png)
    except Exception as e:
        print(json.dumps({"error": f"Spectrogram render failed: {e}"}))
        return 1
    print(json.dumps({"status": "ok", "path": str(out_png)}))
    return 0

def cmd_search(args: argparse.Namespace) -> int:
    os.environ["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
    os.environ["TQDM_DISABLE"] = "1"
    os.environ["TRANSFORMERS_VERBOSITY"] = "error"
    import numpy as np
    import mlx.core as mx
    import mlx_lm

    if not EMBEDDINGS_FILE.exists() or not EMBEDDINGS_IDS_FILE.exists():
        print(json.dumps([]))
        return 1

    matrix = np.load(str(EMBEDDINGS_FILE))
    pids = np.load(str(EMBEDDINGS_IDS_FILE))

    model, tokenizer = mlx_lm.load(EMBEDDING_MODEL_ID)
    tokens = tokenizer.encode(args.query)
    x = mx.array(np.array([tokens], dtype=np.int32))
    out = model.model(x)
    pooled = out.mean(axis=1)
    normed = pooled / mx.linalg.norm(pooled, axis=1, keepdims=True)
    normed_f32 = normed.astype(mx.float32)
    mx.eval(normed_f32)
    q_vec = np.array(normed_f32)[0]

    sims = matrix @ q_vec
    top_k = min(args.limit, len(sims))
    top_indices = np.argpartition(-sims, top_k)[:top_k]
    top_indices = top_indices[np.argsort(-sims[top_indices])]

    con = connect(args.db)
    ordered_pids = [int(pids[idx]) for idx in top_indices]
    score_by_pid = {int(pids[idx]): float(sims[idx]) for idx in top_indices}

    # Single batched lookup instead of one query per result.
    placeholders = ",".join("?" * len(ordered_pids))
    rows_by_id = {}
    if ordered_pids:
        for row in con.execute(
            f"SELECT id, slug, title, genre, subgenre, bpm, music_key, scale, vocal "
            f"FROM prompts WHERE id IN ({placeholders})",
            ordered_pids,
        ):
            rows_by_id[row["id"]] = row

    results = []
    for pid in ordered_pids:   # preserve similarity ranking
        row = rows_by_id.get(pid)
        if row:
            results.append({
                "id": row["slug"],
                "db_id": row["id"],
                "title": row["title"],
                "genre": row["genre"],
                "subgenre": row["subgenre"],
                "bpm": row["bpm"],
                "key": row["music_key"],
                "scale": row["scale"],
                "vocal": row["vocal"],
                "score": round(score_by_pid[pid], 4)
            })
    print(json.dumps(results))
    return 0


def _parse_param_value(raw: str):
    """Coerce a CLI --param value string into bool/int/float, else leave as string."""
    low = raw.lower()
    if low in ("true", "false"):
        return low == "true"
    try:
        return int(raw)
    except ValueError:
        pass
    try:
        return float(raw)
    except ValueError:
        pass
    return raw


# Placeholder/unused controls some plugins expose (e.g. Valhalla's Reserved1-4).
_HIDDEN_PARAM_RE = re.compile(r"^(reserved|unused|dummy|placeholder)\d*$", re.IGNORECASE)


def _format_step_value(v, units) -> str:
    """Render one step label: numbers rounded sensibly with units, strings as-is."""
    if isinstance(v, bool):
        return "On" if v else "Off"
    if isinstance(v, (int, float)):
        a = abs(float(v))
        text = f"{v:.0f}" if a >= 100 else (f"{v:.1f}" if a >= 10 else f"{v:.2f}")
        return f"{text} {units}".strip() if units else text
    return str(v).strip()


def _param_steps(param, units, choice: bool = False, max_steps: int = 201) -> list:
    """[[normalized_start, label], ...] sorted by start, from pedalboard's ranges table.

    Each label is the plugin's own display text at the start of that step ("150%",
    "300.0 ms", "Gemini"), read by moving the parameter there, so units are exactly what
    the plugin shows. Lets a live Audio Unit control (0..1) use the same labels as VST3.
    Choice tables are kept whole; continuous ones are thinned for display only.
    """
    ranges = getattr(param, "ranges", None) or {}
    spans = []
    for key, v in ranges.items():
        if isinstance(key, tuple):
            start, end = float(key[0]), float(key[1])
        else:
            start = end = float(key)
        spans.append((start, end, v))
    spans.sort(key=lambda s: s[0])
    if not choice and len(spans) > max_steps:
        stride = (len(spans) - 1) / (max_steps - 1)
        spans = [spans[round(i * stride)] for i in range(max_steps)]

    original = getattr(param, "raw_value", None)
    steps = []
    try:
        for start, end, v in spans:
            label = None
            # Choices: the declared table value ("Off", "Gemini") is authoritative; some
            # plugins (e.g. Wider) report stale display text right after a raw change.
            if not choice and original is not None:
                try:
                    param.raw_value = min(max(start, 0.0), 1.0)
                    label = str(param.string_value).strip() or None
                except Exception:
                    label = None
            steps.append([round(start, 5), label or _format_step_value(v, units)])
    finally:
        if original is not None:
            try:
                param.raw_value = original
            except Exception:
                pass
    return steps


def _coerce_for_param(param, raw: str):
    """Coerce a UI/CLI value to the type the plugin parameter declares.

    Booleans accept On/Off/true/false/1/0; list (str) params keep the exact string so
    choices like "Off" or "120 Hz" aren't mangled; numbers strip unit suffixes ("150%").
    Falls back to generic parsing when the type is unknown.
    """
    ptype = getattr(param, "type", None) if param is not None else None
    text = raw.strip()
    if ptype is bool:
        return text.lower() in ("on", "true", "1", "yes")
    if ptype is str:
        return text
    if ptype in (int, float):
        m = re.match(r"^\s*[-+]?\d*\.?\d+", text)
        if m:
            num = float(m.group(0))
            return int(num) if ptype is int else num
    return _parse_param_value(text)


def cmd_effect(args: argparse.Namespace) -> int:
    """Load an external VST3/AU plugin via pedalboard and either list its parameters
    or render the input audio through it.

    Point at any plugin path:
        studio.py effect in.wav --plugin "/path/My Plugin.vst3" --list-params
        studio.py effect in.wav --plugin "/path/My Plugin.vst3" --param width=150 --output out.wav
    """
    try:
        from pedalboard import load_plugin
        from pedalboard.io import AudioFile
        from pedalboard import VST3Plugin, AudioUnitPlugin
    except ImportError as e:
        print(json.dumps({"error": f"pedalboard unavailable: {e}"}))
        return 1

    plugin_path = Path(args.plugin).expanduser()
    if not plugin_path.exists():
        print(json.dumps({"error": f"Plugin not found: {plugin_path}"}))
        return 1

    # Multi-plugin containers: a .vst3 may host several plugins; let the user pick one.
    try:
        if plugin_path.suffix.lower() == ".vst3":
            names = VST3Plugin.get_plugin_names_for_file(str(plugin_path))
        elif plugin_path.suffix.lower() == ".component":
            names = AudioUnitPlugin.get_plugin_names_for_file(str(plugin_path))
        else:
            names = []
    except Exception:
        names = []

    try:
        plugin = load_plugin(str(plugin_path), plugin_name=args.plugin_name) \
            if args.plugin_name else load_plugin(str(plugin_path))
    except Exception as e:
        print(json.dumps({"error": f"Could not load plugin: {e}", "available_plugins": names}))
        return 1

    # Introspection: dump the plugin's parameters and exit.
    if args.list_params:
        params = {}
        for pname, p in plugin.parameters.items():
            info = {"value": str(getattr(p, "string_value", getattr(p, "raw_value", "")))}
            for attr in ("min_value", "max_value", "label", "units"):
                if hasattr(p, attr):
                    info[attr] = getattr(p, attr)
            ptype = getattr(p, "type", None)
            info["type"] = getattr(ptype, "__name__", str(ptype)) if ptype else None
            # String-typed params are enums with a fixed list; the UI shows a menu.
            if ptype is str:
                info["options"] = [str(v) for v in (getattr(p, "valid_values", None) or [])]
            info["choice"] = ptype in (str, bool)
            info["hidden"] = bool(_HIDDEN_PARAM_RE.match(pname))
            # Normalized 0..1 position, shared by the plugin's VST3 and AU builds.
            info["raw"] = float(getattr(p, "raw_value", 0.0))
            # Normalized-value -> display-label table. The plugin's Audio Unit build uses the
            # same 0..1 values, so the app can label live AU controls with real units.
            info["steps"] = _param_steps(p, getattr(p, "units", None), choice=info["choice"])
            params[pname] = info
        print(json.dumps({
            "plugin": plugin.name,
            "manufacturer": getattr(plugin, "manufacturer_name", ""),
            "is_effect": getattr(plugin, "is_effect", None),
            "is_instrument": getattr(plugin, "is_instrument", None),
            "available_plugins": names,
            "parameters": params,
        }, default=str, separators=(",", ":")))
        return 0

    if getattr(plugin, "is_instrument", False):
        print(json.dumps({"error": f"'{plugin.name}' is an instrument, not an effect; cannot process audio through it."}))
        return 1

    # Apply requested parameters (name=value).
    applied = {}
    for item in (args.param or []):
        if "=" not in item:
            print(json.dumps({"error": f"Bad --param '{item}'; expected name=value"}))
            return 1
        name, _, value = item.partition("=")
        name, value = name.strip(), value.strip()
        try:
            setattr(plugin, name, _coerce_for_param(plugin.parameters.get(name), value))
            applied[name] = value
        except Exception as e:
            msg = str(e)
            if len(msg) > 200:
                msg = msg[:200].rsplit(" ", 1)[0] + "…"
            print(json.dumps({"error": f"Could not set '{name}' to '{value}': {msg}"}))
            return 1

    # Normalized 0..1 positions (name=0.42). Same scale as the plugin's Audio Unit build,
    # so the app can drive VST3 previews from the same controls it uses for live AUs.
    for item in (args.raw or []):
        name, sep, value = item.partition("=")
        name, value = name.strip(), value.strip()
        par = plugin.parameters.get(name)
        try:
            if not sep or par is None:
                raise ValueError("unknown parameter" if par is None else "expected name=value")
            par.raw_value = min(max(float(value), 0.0), 1.0)
            applied[name] = par.string_value
        except Exception as e:
            print(json.dumps({"error": f"Could not set '{name}' to raw '{value}': {str(e)[:200]}"}))
            return 1

    src = Path(args.input).expanduser().resolve()
    if not src.exists():
        print(json.dumps({"error": f"Input file not found: {src}"}))
        return 1
    dst = Path(args.output).expanduser().resolve() if args.output else \
        src.with_name(f"{src.stem}_fx{src.suffix}")

    import numpy as np
    emit("start", component="effect", level="info",
         message=f"Processing {src.name} through {plugin.name}")
    with AudioFile(str(src)) as f:
        audio = f.read(f.frames)
        sr = f.samplerate
    processed = plugin(audio, sr)
    peak = float(np.max(np.abs(processed))) if processed.size else 0.0
    if peak > 1.0:
        processed = processed / peak   # guard against plugin-induced clipping
    with AudioFile(str(dst), "w", sr, processed.shape[0]) as f:
        f.write(processed)

    emit("effect_done", component="effect", level="info", input=str(src), output=str(dst),
         plugin=plugin.name, params=applied)
    print(json.dumps({
        "status": "ok", "plugin": plugin.name, "input": str(src), "output": str(dst),
        "applied_params": applied,
        "size_bytes": os.path.getsize(dst) if dst.exists() else 0,
    }, default=str))
    return 0

def cmd_master(args: argparse.Namespace) -> int:
    src = Path(args.input).resolve()
    if not src.exists():
        emit("error", component="mastering", level="error", message=f"Input file not found: {src}")
        print(f"Error: Input file not found: {src}", file=sys.stderr)
        return 1

    src_ext = src.suffix.lower().lstrip(".")
    src_tags = read_audio_tags(src)
    emit("start", component="mastering", level="info", message=f"Mastering {src.name}")

    # The DSP chain reads/writes WAV. Decode non-WAV sources to a temp WAV first.
    work_wav = src
    tmp_decoded: Path | None = None
    if src_ext != "wav":
        tmp_decoded = src.with_name(f"{src.stem}.master_src.wav")
        try:
            if src_ext == "flac":
                _wav_via_afconvert(str(src), str(tmp_decoded), "WAVE", "LEI16")
            else:
                # mp3 / m4a / aac → PCM WAV via CoreAudio
                _wav_via_afconvert(str(src), str(tmp_decoded), "WAVE", "LEI16")
            work_wav = tmp_decoded
        except Exception as e:
            emit("error", component="mastering", level="error", message=f"Could not decode {src.name} to WAV: {e}")
            print(f"Error: decode failed: {e}", file=sys.stderr)
            return 1

    mastered_wav = src.with_name(f"{src.stem}_mastered.wav")
    try:
        res = apply_mastering_chain(
            input_wav=work_wav,
            output_wav=mastered_wav,
            enable_hf_repair=args.hf_repair,
            enable_artifact_reduction=args.artifact_reduction,
            eq_low_db=args.eq_low,
            eq_mid_db=args.eq_mid,
            eq_high_db=args.eq_high,
            target_lufs=args.target_lufs,
        )
    except Exception as e:
        emit("error", component="mastering", level="error", message=f"Mastering failed: {e}")
        print(f"Error: mastering failed: {e}", file=sys.stderr)
        return 1
    finally:
        if tmp_decoded is not None and tmp_decoded.exists():
            try: tmp_decoded.unlink()
            except Exception: pass

    # Re-encode the mastered WAV back to the source format so it drops into the same player.
    final_output = str(mastered_wav)
    if src_ext in ("mp3", "m4a", "flac"):
        mastered_encoded = src.with_name(f"{src.stem}_mastered.{src_ext}")
        conv = convert_audio(str(mastered_wav), src_ext, str(mastered_encoded))
        if conv.get("status") == "ok":
            final_output = conv["path"]
            try: mastered_wav.unlink()
            except Exception: pass
        else:
            emit("log", component="mastering", level="warn",
                 message=f"Re-encode to {src_ext} failed ({conv.get('error')}); keeping WAV")

    # Carry source tags onto the mastered file and refresh measured loudness/peak.
    if src_tags:
        merged = dict(src_tags)
        for k_res, k_tag in (("lufs", "lufs"), ("peak_db", "post_peak_db")):
            if res.get(k_res) is not None:
                merged[k_tag] = res[k_res]
        tag_audio_file(final_output, merged)

    size_mb = round(os.path.getsize(final_output) / (1024 * 1024), 2)
    res["output"] = final_output
    res["size_mb"] = size_mb
    emit("mastered", component="mastering", level="info",
         input=str(src), output=final_output, lufs=res.get("lufs"),
         peak_db=res.get("peak_db"), hf_repair=args.hf_repair,
         artifact_reduction=args.artifact_reduction, size_mb=size_mb)
    print(json.dumps(res, indent=2))
    return 0

# ===========================================================================
# Argument Parser
# ===========================================================================

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="MusicStudio Python Backend")
    p.add_argument("--db", type=Path, default=DB_PATH, help="Path to SQLite database")
    p.add_argument("--output-dir", type=Path, default=OUTPUT_DIR, help="Path to output rendered audio")

    sub = p.add_subparsers(dest="cmd", required=True)

    # init
    p_init = sub.add_parser("init")
    p_init.set_defaults(func=cmd_init)

    # models
    p_models = sub.add_parser("models")
    p_models.set_defaults(func=cmd_models)

    # stats
    p_stats = sub.add_parser("stats")
    p_stats.set_defaults(func=cmd_stats)

    # schema (FR-003)
    p_schema = sub.add_parser("schema", help="Database schema migration management")
    p_schema.add_argument("--status", action="store_true", help="Report current schema version and pending migrations")
    p_schema.add_argument("--migrate", action="store_true", help="Apply all pending schema migrations")
    p_schema.add_argument("--backup", action="store_true", help="Backup database without migrating")
    p_schema.set_defaults(func=cmd_schema)

    # generate
    p_gen = sub.add_parser("generate")
    p_gen.add_argument("--model", default="minimax_music3:MiniMax-Music3-mxfp8")
    p_gen.add_argument("--caption", default="")
    p_gen.add_argument("--style", default="")
    p_gen.add_argument("--lyrics", default="")
    p_gen.add_argument("--duration", type=float, default=60.0)
    p_gen.add_argument("--steps", type=int, default=None)
    p_gen.add_argument("--guidance", type=float, default=None)
    p_gen.add_argument("--cfg-scale", type=float, default=None)
    p_gen.add_argument("--seed", type=int, default=None)
    p_gen.add_argument("--format", default="mp3", choices=["wav", "mp3", "m4a", "flac"])
    p_gen.add_argument("--cot", default="full", choices=["full", "melody", "off"])
    p_gen.add_argument("--abc-file", default=None)
    p_gen.set_defaults(func=cmd_generate)

    # worker
    p_worker = sub.add_parser("worker")
    p_worker.set_defaults(func=cmd_worker)

    # SongBench retry/manual verification
    p_songbench = sub.add_parser("songbench", help="Evaluate one committed generation")
    p_songbench.add_argument("audio_path", help="Generation audio path")
    p_songbench.add_argument("--generation-id", type=int, required=True)
    p_songbench.set_defaults(func=cmd_songbench)

    # convert
    p_conv = sub.add_parser("convert")
    p_conv.add_argument("input", help="Source audio file")
    p_conv.add_argument("format", choices=["wav", "mp3", "m4a", "flac"], help="Target format")
    p_conv.add_argument("--output", default=None, help="Destination file path")
    p_conv.add_argument("--tags-from", default=None, help="Copy tags from this file instead of the input")
    p_conv.set_defaults(func=cmd_convert)

    # tags (two-way DB<->file sync)
    p_tags = sub.add_parser("tags", help="Read audio tags as JSON, or write via --write JSON")
    p_tags.add_argument("input", help="Audio file")
    p_tags.add_argument("--write", default=None, help="JSON metadata blob to write into the file")
    p_tags.set_defaults(func=cmd_tags)

    # spectrogram (cached mel-spectrogram PNG)
    p_spec = sub.add_parser("spectrogram", help="Render/cache a mel-spectrogram PNG")
    p_spec.add_argument("input", help="Audio file")
    p_spec.add_argument("--output", default=None, help="PNG path (default: .<stem>.spectrogram.png)")
    p_spec.add_argument("--force", action="store_true", help="Re-render even if cached")
    p_spec.set_defaults(func=cmd_spectrogram)

    # reconcile (DB<->file mtime-gated sync)
    p_rec = sub.add_parser("reconcile", help="Re-read file tags into DB where the file is newer")
    p_rec.set_defaults(func=cmd_reconcile)

    # effect (load an external VST3/AU plugin via pedalboard)
    p_fx = sub.add_parser("effect", help="Load a VST3/AU plugin and process audio through it")
    p_fx.add_argument("input", help="Input audio file")
    p_fx.add_argument("--plugin", required=True, help="Path to a .vst3 or .component plugin")
    p_fx.add_argument("--plugin-name", default=None, help="Sub-plugin name for multi-plugin containers")
    p_fx.add_argument("--param", action="append", default=[], help="Plugin parameter name=value (repeatable)")
    p_fx.add_argument("--raw", action="append", default=[], help="Normalized 0..1 parameter name=value (repeatable)")
    p_fx.add_argument("--list-params", action="store_true", help="Print the plugin's parameters as JSON and exit")
    p_fx.add_argument("--output", default=None, help="Output path (default: <stem>_fx.<ext>)")
    p_fx.set_defaults(func=cmd_effect)

    # search
    p_search = sub.add_parser("search")
    p_search.add_argument("query", help="Semantic query string")
    p_search.add_argument("--limit", type=int, default=50)
    p_search.set_defaults(func=cmd_search)


    # tokens (FR-007)
    p_tok = sub.add_parser("tokens", help="Calculate prompt tokens against MiniMax budget")
    p_tok.add_argument("--prompt-slug", default="", help="Prompt slug to evaluate")
    p_tok.add_argument("--caption", default="", help="Music caption")
    p_tok.add_argument("--lyrics", default="", help="Song lyrics")
    p_tok.set_defaults(func=cmd_tokens)

    # master (FR-013)
    p_mast = sub.add_parser("master", help="Apply mastering DSP chain to audio file")
    p_mast.add_argument("input", help="Source WAV audio file")
    p_mast.add_argument("--output", default=None, help="Output WAV path (default: <input>_mastered.wav)")
    p_mast.add_argument("--hf-repair", action="store_true", help="Apply +1.5dB high frequency air lift (>10kHz)")
    p_mast.add_argument("--artifact-reduction", action="store_true", help="Apply bounded spectral artifact reduction")
    p_mast.add_argument("--eq-low", type=float, default=0.0, help="Low shelf EQ gain in dB (<250Hz)")
    p_mast.add_argument("--eq-mid", type=float, default=0.0, help="Mid peak EQ gain in dB (500Hz-4kHz)")
    p_mast.add_argument("--eq-high", type=float, default=0.0, help="High shelf EQ gain in dB (>6kHz)")
    p_mast.add_argument("--target-lufs", type=float, default=-14.0, help="Target loudness (-14.0 LUFS)")
    p_mast.set_defaults(func=cmd_master)

    # loudness (FR-009)
    p_loud = sub.add_parser("loudness", help="Measure and normalise audio loudness (-14 LUFS)")
    p_loud.add_argument("input", help="Input WAV file to measure and normalise")
    p_loud.add_argument("--target-lufs", type=float, default=-14.0, help="Target integrated loudness in LUFS")
    p_loud.add_argument("--target-peak", type=float, default=-1.0, help="Target peak limit in dBTP")
    p_loud.set_defaults(func=cmd_loudness)


    # render (FR-011)
    p_ren = sub.add_parser("render", help="Render prompt text for a specific model")
    p_ren.add_argument("--prompt-slug", required=True, help="Prompt slug to render")
    p_ren.add_argument("--model", default="minimax_music3:MiniMax-Music3-mxfp8", help="Model ID")
    p_ren.set_defaults(func=cmd_render)
    # estimate (FR-008)
    p_est = sub.add_parser("estimate", help="Compute phase-aware ETA prediction")
    p_est.add_argument("--model", default="minimax_music3:MiniMax-Music3-mxfp8", help="Target model ID")
    p_est.add_argument("--duration", type=float, default=60.0, help="Target duration in seconds")
    p_est.add_argument("--steps", type=int, default=None, help="Generation steps")
    p_est.add_argument("--cot", default="full", choices=["full", "melody", "off"], help="YuE2 CoT mode")
    p_est.set_defaults(func=cmd_estimate)
    return p

def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    ret = args.func(args)
    sys.exit(ret or 0)

if __name__ == "__main__":
    main()
