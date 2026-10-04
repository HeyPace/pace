#!/usr/bin/env python3
"""
Generate UNLABELLED synthetic planner step states for the next-step router
(milestone 2a of docs/product/prds/next-step-router.md).

Each output row is one moment in the planner loop:

    request + screen elements + 0..N completed steps  →  "best next step?"

A separate teacher-labelling script labels these rows later. `intended_label`
is only this generator's own guess, used for coverage stats and sanity checks.
It is NOT a training label.

Stdlib only. No network. No LLM calls. Deterministic for a given --seed.

Why request text comes from real paraphrase corpora
---------------------------------------------------
posttrainllm `pace-intent-router-v8` hit 95.5% on its template holdout and 57%
on a sealed set because template phrasing overfit. So request text is drawn
from real (or at least independently written) paraphrase corpora found offline.
Templates are used for screen elements and completed-step results, and only as
a fallback for tools that the corpora barely cover (reported as source
"template" so the gap stays visible).

Source → Pace label mapping (rows whose intent is not listed are DROPPED)
-----------------------------------------------------------------------
evals/intent-corpus/*.jsonl  (fields: transcript, intent)
    screenAction       → clause parser (TOOL_CLAUSE_PATTERNS below): split on
                         "then"/"and then"/verb-led "and"; every clause must map to
                         a tool or to a destructive step, else the row is dropped.
                         1 clause → single tool / compose / click; 2+ → multi-step.
    screenDescription  → RESPOND (describe the screen)
    pureKnowledge, research, chitchat → RESPOND (out of scope)
    unknown            → RESPOND (unsupported) ONLY when no tool pattern and no
                         destructive pattern matches (the bucket holds mislabels such
                         as "the screen is too bright")
    phoneLargeModel    → dropped (an escalation request, not a next-step decision)
SetFit/amazon_massive_intent_en-US (MASSIVE en-US, label_text)
    audio_volume_up/down/mute → volume       iot_* (room lights, plugs, vacuum) → RESPOND
    calendar_query     → calendar            calendar_set → reminder if "remind", else calendar_create
    calendar_remove    → ASK_USER (destructive)
    lists_createoradd  → reminder if "remind", else things
    lists_remove       → ASK_USER (destructive)
    email_sendemail    → mail (compose)      play_music, music_settings → music
    qa_*, weather_query, news_query, datetime_*, recommendation_*, cooking_*,
    transport_query, transport_traffic, general_*, social_query,
    email_addcontact, email_querycontact, takeaway_*, transport_taxi,
    transport_ticket, play_game → RESPOND
    alarm_*, email_query, lists_query, music_query/likeness/dislikeness,
    play_podcasts/radio/audiobook, social_post, audio_volume_other → dropped
    (no single Pace label is clearly right)
OpenVoiceOS/intents-for-eval en-US (expected_intent)
    calendar:create_event → calendar_create  calendar:list_events/next_event → calendar
    calendar:cancel_event → ASK_USER         communication:send_message → messages (compose)
    media:play_song/pause/resume/skip_track → music   media:set_volume, system_control:mute_system → volume
    system_control:set_brightness_screen → brightness timers_alarms:set_timer → start_timer
    search_qa:*, weather:*, news:*, navigation:*, smarthome:*, communication:call/video/hang_up,
    system_control:change_language, None (chit-chat / gibberish) → RESPOND
    everything else → dropped
Team-ACE/ToolACE data.json (first user turn, 5..30 words, single line)
    → RESPOND (requests for external APIs Pace has no tool for); rows whose
      text matches any Pace tool or destructive pattern are dropped.

Not usable offline (reported, skipped): clinc/clinc_oos is parquet and pyarrow is
not installed; AmazonScience/massive and Salesforce/xlam-function-calling-60k have
only their loader/README cached, no data.

Splits
------
"sealed" (~10%) is partitioned by SOURCE PHRASING: every candidate request is
reduced to a core key (lowercase, no punctuation, digits → #, wake words /
politeness fillers / articles removed). The key's hash picks the split, so a
phrasing and its filler variants never straddle splits. A final pass drops any
train row whose request is a near-duplicate (token Jaccard ≥ 0.8) of a sealed
request. Any candidate that matches or near-duplicates a USER line from
evals/fm-fixtures*/*.txt is excluded from both splits.

Usage:
    python3 scripts/generate-router-step-states.py
    python3 scripts/generate-router-step-states.py --total 20000 --seed 7 --output-dir evals/router-data
"""

import argparse
import collections
import glob
import hashlib
import importlib.util
import json
import math
import random
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# The experiment harness has a dashed filename, so it is loaded by path. Reusing its
# catalog loader and input serialisation keeps generator, teacher and eval in lockstep.
_experiment_module_spec = importlib.util.spec_from_file_location(
    "experiment_jev_planner", REPO_ROOT / "scripts" / "experiment-jev-planner.py")
experiment_jev_planner = importlib.util.module_from_spec(_experiment_module_spec)
_experiment_module_spec.loader.exec_module(experiment_jev_planner)
load_tool_catalog = experiment_jev_planner.load_tool_catalog
router_input_text = experiment_jev_planner.router_input_text
router_label_descriptions = experiment_jev_planner.router_label_descriptions
CONTROL_LABEL_DESCRIPTIONS = experiment_jev_planner.CONTROL_LABEL_DESCRIPTIONS

HUGGING_FACE_HUB_DIRECTORY = Path.home() / ".cache" / "huggingface" / "hub"
INTENT_CORPUS_DIRECTORY = REPO_ROOT / "evals" / "intent-corpus"
SEALED_SPLIT_FRACTION = 0.10
NEAR_DUPLICATE_JACCARD_THRESHOLD = 0.8

SCENARIO_SHARE_OF_TOTAL = {
    "single_tool_first_step": 0.20,
    "click_unique_target": 0.08,
    "ambiguous_targets": 0.08,
    "destructive": 0.08,
    "out_of_scope": 0.09,
    "describe_screen": 0.05,
    "compose": 0.07,
    "multi_step_intermediate": 0.13,
    "already_done": 0.17,
    "after_failure": 0.05,
}


# ================================================================ text normalisation

LEADING_FILLER_PATTERN = re.compile(
    r"^(?:(?:okay|ok|hey|hi|hello|yo|so|um+|uh+|like|well|alright|right|now|pace|"
    r"please|just|quickly|actually|you know|i mean|and)[,.!]?\s+)+")
REQUEST_PREFIX_PATTERN = re.compile(
    r"^(?:can you|could you|would you|will you|can u|i want you to|i need you to|i'd like you to|"
    r"i would like you to|how about|i was wondering if you could|i was wondering|let's|lets|go ahead and|"
    r"please|would you mind|do me a favor and|help me|i want to|i need to|i wanna)\s+")
TRAILING_FILLER_PATTERN = re.compile(
    r"(?:\s+|,\s*)(?:please|for me|thanks|thank you|if you can|if you could|right now|real quick|"
    r"now|quickly|asap|thx|ok|okay|pace)\s*[?.!]*$")
ARTICLE_AND_POSSESSIVE_WORDS = {"the", "a", "an", "my", "some"}
# Disfluencies the synthetic intent corpus sprinkles mid-sentence ("go to downloads and um open").
INTERNAL_FILLER_PATTERN = re.compile(r"\b(?:um+|uh+|hmm+|basically|sort of|kind of|you know|like)\b,?\s*")
# "no wait", "i mean", "scratch that": the speaker changed their mind mid-request. Which clause
# survives is a judgement call, so those rows are dropped rather than given a guessed plan.
SELF_CORRECTION_PATTERN = re.compile(r"\b(?:no wait|wait no|i mean|sorry|scratch that|actually no|hmm,? no|no,? no)\b")
# Free-text slot markers: everything after them is content, not command structure.
CONTENT_SLOT_MARKER_WORDS = {"called", "named", "titled", "saying", "subject"}
MAX_CANDIDATES_PER_PHRASING_SKELETON = 6


def normalized_request_text(request_text):
    lowered = request_text.lower().replace("’", "'")
    without_punctuation = re.sub(r"[^\w\s']", " ", lowered)
    return re.sub(r"\s+", " ", without_punctuation).strip()


def strip_conversational_fillers(request_text):
    """Removes wake words, politeness and hedges so the clause parser sees the command itself."""
    stripped = request_text.lower().replace("’", "'").strip()
    stripped = re.sub(r"[?.!]+$", "", stripped).strip()
    for _ in range(4):
        before = stripped
        stripped = LEADING_FILLER_PATTERN.sub("", stripped)
        stripped = REQUEST_PREFIX_PATTERN.sub("", stripped)
        stripped = TRAILING_FILLER_PATTERN.sub("", stripped)
        stripped = stripped.strip(" ,")
        if stripped == before:
            break
    return stripped


def core_phrasing_key(request_text):
    """The unit the sealed split is partitioned by: filler variants and number variants collapse together."""
    core_text = normalized_request_text(strip_conversational_fillers(request_text))
    core_text = INTERNAL_FILLER_PATTERN.sub("", core_text)
    core_text = re.sub(r"\d+", "#", core_text)
    core_words = [word for word in core_text.split() if word not in ARTICLE_AND_POSSESSIVE_WORDS]
    return " ".join(core_words)


def phrasing_skeleton_key(core_key):
    """Command structure with free-text slots and names blanked: "open notes and create a note called
    groceries" and "... called the nda" share one skeleton. The sealed split is partitioned by skeleton
    so sealed tests unseen sentence structure, and each skeleton is capped so the templated parts of the
    intent corpus cannot dominate."""
    skeleton_words = []
    for word in core_key.split():
        if word in CONTENT_SLOT_MARKER_WORDS:
            skeleton_words.append(word + " <slot>")
            break
        skeleton_words.append("<name>" if word.capitalize() in PERSON_NAME_SET or word in APP_AND_SITE_WORD_SET else word)
    return " ".join(skeleton_words)


def stable_unit_interval(text, seed):
    digest = hashlib.sha256(f"{seed}:{text}".encode()).hexdigest()
    return int(digest[:12], 16) / float(16 ** 12)


def split_for_core_key(core_key, seed):
    return "sealed" if stable_unit_interval("split:" + core_key, seed) < SEALED_SPLIT_FRACTION else "train"


class NearDuplicateIndex:
    """Token-set Jaccard lookup. Candidates are found through each text's rarest tokens so the
    check stays fast over tens of thousands of phrasings."""

    def __init__(self):
        self.token_sets = []
        self.postings_by_token = collections.defaultdict(list)

    def add(self, core_key):
        token_set = frozenset(core_key.split())
        if not token_set:
            return
        index = len(self.token_sets)
        self.token_sets.append(token_set)
        for token in token_set:
            self.postings_by_token[token].append(index)

    def contains_near_duplicate(self, core_key, threshold=NEAR_DUPLICATE_JACCARD_THRESHOLD):
        query_tokens = frozenset(core_key.split())
        if not query_tokens:
            return False
        # Tie-break on the token itself: set order is hash-randomised per process, and --seed must be reproducible.
        rarest_tokens = sorted(query_tokens, key=lambda token: (len(self.postings_by_token.get(token, ())), token))[:2]
        candidate_indexes = set()
        for token in rarest_tokens:
            candidate_indexes.update(self.postings_by_token.get(token, ()))
        for candidate_index in candidate_indexes:
            candidate_tokens = self.token_sets[candidate_index]
            if candidate_tokens == query_tokens:
                return True
            # Very short phrasings ("send it") only count as duplicates on exact match.
            if min(len(candidate_tokens), len(query_tokens)) < 3:
                continue
            jaccard = len(candidate_tokens & query_tokens) / len(candidate_tokens | query_tokens)
            if jaccard >= threshold:
                return True
        return False


def load_fixture_request_exclusion_index():
    """Every USER line in the harness fixtures, so no generated request leaks into either split."""
    exclusion_index = NearDuplicateIndex()
    fixture_user_line_count = 0
    for fixture_path in sorted(glob.glob(str(REPO_ROOT / "evals" / "fm-fixtures*" / "*.txt"))):
        for raw_line in Path(fixture_path).read_text().splitlines():
            if raw_line.startswith("USER:"):
                exclusion_index.add(core_phrasing_key(raw_line.split(":", 1)[1]))
                fixture_user_line_count += 1
    return exclusion_index, fixture_user_line_count


# ================================================================ app / site vocabulary

KNOWN_APP_NAMES = [
    "Safari", "Mail", "Messages", "Notes", "Finder", "Slack", "Spotify", "Music", "Calendar", "Reminders",
    "Things", "Xcode", "VS Code", "Terminal", "Keynote", "Pages", "Numbers", "Preview", "System Settings",
    "Zoom", "Chrome", "Firefox", "Figma", "Notion", "Photos", "Maps", "Discord", "WhatsApp", "Calculator",
    "TextEdit", "Activity Monitor", "iMovie", "GarageBand", "Podcasts", "Books", "Stocks", "Weather",
    "Clock", "FaceTime", "App Store", "Voice Memos", "QuickTime Player", "Telegram", "Microsoft Teams",
    "Linear", "Arc", "Obsidian", "Cursor", "Raycast", "1Password", "Shortcuts", "Contacts", "News", "TV",
]
APP_NAME_ALIASES = {
    "vscode": "VS Code", "visual studio code": "VS Code", "settings": "System Settings",
    "system preferences": "System Settings", "teams": "Microsoft Teams", "google chrome": "Chrome",
    "quicktime": "QuickTime Player", "imessage": "Messages", "apple music": "Music", "the browser": "Safari",
    "browser": "Safari", "my browser": "Safari", "outlook": "Microsoft Outlook", "word": "Microsoft Word",
    "excel": "Microsoft Excel",
}
APP_NAME_BY_LOWERCASE = {app_name.lower(): app_name for app_name in KNOWN_APP_NAMES}
APP_NAME_BY_LOWERCASE.update(APP_NAME_ALIASES)

KNOWN_WEBSITE_DOMAINS = {
    "youtube": "youtube.com", "github": "github.com", "reddit": "reddit.com", "gmail": "mail.google.com",
    "google": "google.com", "wikipedia": "wikipedia.org", "amazon": "amazon.com", "netflix": "netflix.com",
    "twitter": "x.com", "x": "x.com", "facebook": "facebook.com", "instagram": "instagram.com",
    "linkedin": "linkedin.com", "tiktok": "tiktok.com", "hacker news": "news.ycombinator.com",
    "the verge": "theverge.com", "techcrunch": "techcrunch.com", "new york times": "nytimes.com",
    "the new york times": "nytimes.com", "arxiv": "arxiv.org", "stackoverflow": "stackoverflow.com",
    "stack overflow": "stackoverflow.com", "huggingface": "huggingface.co", "hugging face": "huggingface.co",
    "anthropic": "anthropic.com", "openai": "openai.com", "vercel": "vercel.com", "netlify": "netlify.com",
    "cloudflare": "dash.cloudflare.com", "aws": "console.aws.amazon.com", "medium": "medium.com",
    "colab": "colab.research.google.com", "replit": "replit.com", "icloud": "icloud.com",
    "protonmail": "mail.proton.me", "dropbox": "dropbox.com", "bbc": "bbc.com", "espn": "espn.com",
}
APP_AND_SITE_WORD_SET = ({word for app_name in KNOWN_APP_NAMES for word in app_name.lower().split()}
                         | {word for site_name in KNOWN_WEBSITE_DOMAINS for word in site_name.split()}
                         | set(KNOWN_WEBSITE_DOMAINS.values())) - {"the", "app", "x", "news"}
FOLDER_PATH_BY_NAME = {
    "downloads": "~/Downloads", "desktop": "~/Desktop", "documents": "~/Documents",
    "applications": "/Applications", "home": "~", "pictures": "~/Pictures", "movies": "~/Movies",
    "music": "~/Music", "trash": "~/.Trash", "icloud drive": "~/Library/Mobile Documents",
}

PERSON_NAMES = ["Alex", "Priya", "Sam", "Jordan", "Mei", "Diego", "Fatima", "Noah", "Hannah", "Kenji",
                "Olivia", "Marcus", "Aisha", "Tom", "Lucia", "Ravi", "mom", "dad", "Chris", "Dana"]
EMAIL_SUBJECTS = ["Q3 planning", "Invoice #4021", "Re: launch checklist", "Lunch Friday?", "Contract draft v2",
                  "Your order has shipped", "Standup notes", "Flight confirmation", "Design review feedback",
                  "Offsite agenda", "Weekly metrics", "PR #812 review requested", "Rent reminder"]
FILE_NAMES = ["Q3 report.pdf", "budget.numbers", "IMG_2041.HEIC", "notes.txt", "Presentation.key",
              "invoice-0423.pdf", "Screenshot 2026-09-12 at 10.14.png", "resume_final.docx", "data.csv",
              "logo.svg", "meeting-recording.m4a", "archive.zip", "contract-signed.pdf", "draft.pages"]
MUSIC_TRACK_NAMES = ["Blinding Lights", "Clair de Lune", "Redbone", "Midnight City", "Holocene", "Nights",
                     "Dreams", "Take Five", "Electric Feel", "Weightless", "Bad Guy", "Lofi Study Mix"]
SAMPLE_TYPED_TEXTS = ["hello world", "meeting moved to 3pm", "best pizza near me", "quarterly revenue chart",
                      "sounds good, see you then", "how to center a div", "flights to Lisbon in March",
                      "Thanks for the update!", "npm run build", "weather tomorrow"]
REMINDER_TITLES = ["call the dentist", "follow up with Priya", "pay the electricity bill", "water the plants",
                   "pick up dry cleaning", "send the deck to Sam", "renew passport", "book the flight"]
TIMER_LABELS = ["tea", "pasta", "focus", "laundry", "break", "pomodoro", "eggs", "stretch"]
PERSON_NAME_SET = set(PERSON_NAMES) | {"John", "Sarah", "Mike", "Emma", "Liam", "Nora", "Kate", "James", "Jude", "Theo",
                                       "Laura", "Max", "Daniel", "Bob", "Lauren", "Rachel", "Emily", "David", "Anna"}
FLOW_NAMES = ["morning standup setup", "focus mode", "end of day wrap", "deploy checklist", "podcast recording"]
SHORTCUT_NAMES = ["Morning Routine", "Log Water", "Start Focus", "Resize Images", "Home Arrival", "Daily Note"]


# ================================================================ clause → tool mapping

DESTRUCTIVE_REQUEST_PATTERN = re.compile(
    r"\b(delete|deleting|trash|erase|wipe|remove|discard|uninstall|empty the|force quit|cancel (?:my|the|all)|"
    r"unsubscribe|purchase|buy|pay|checkout|place (?:the|my)? ?order|transfer \$?\d|format (?:the|my)|"
    r"send it|send that|send the (?:email|message|text|draft)|send now|submit (?:it|the form|the order)|"
    r"clear (?:my|the|all) (?:history|inbox|cache|data|messages))\b")
# A destructive verb inside content ("remind me to BUY milk", "text Sam to DELETE the draft") is not
# itself destructive, so content-creating leading verbs skip the destructive gate.
CONTENT_CREATING_LEADING_VERB_PATTERN = re.compile(
    r"^(?:remind|set a reminder|add|put|jot|note|text|message|tell|email|e-mail|write|create|schedule|make a note|reply|respond|"
    r"make a reminder|don't let me forget|make sure i remember|draft|compose|"
    r"send (?!it\b|that\b|this\b|them\b|now\b|the\b|everything\b|all\b)\w+ (?:a |an )?(?:text|message|email|note|dm))\b")
UNSUPPORTED_CLAUSE_PATTERN = re.compile(
    r"\b(alarm|wake me|screenshot|screen shot|log ?in|sign in with|credentials|directions|call (?!it\b)|facetime|"
    r"video call|reschedule|rename|duplicate|share (?:it|this|that|them|the \w+) with|create an agenda|move (?:my|the) meeting|navigate to (?![\w-]+\.\w))")
# Retrieval of existing content ("find the email from Mia about the schedule") has no single Pace tool;
# web searches are the exception and are caught by the open_url pattern.
RETRIEVAL_LEADING_VERB_PATTERN = re.compile(r"^(?:find|look for|search for|search my|read|show me the (?:email|message|file))\b")
KEYBOARD_LEADING_PATTERN = re.compile(r"^(?:press|hit|use|do)\s+(?:the\s+)?(?:cmd|command|ctrl|control|option|alt|shift|escape|esc|enter|return|tab key|space ?bar|f\d{1,2})\b")
CLICK_LEADING_VERB_PATTERN = re.compile(r"^(?:click|tap|hit|press|toggle|select|choose|push)\b")
# Leading-verb rules run before the ordered keyword patterns: the first verb decides the tool when it
# names one ("text Sam to remind him" is a message, not a reminder).
LEADING_VERB_TOOL_PATTERNS = [
    ("messages", re.compile(r"^(?:text|imessage|sms|message|dm|shoot \w+ a (?:text|message)|tell \w+ (?:that|i'm|i am|i'll|we|to|on|over|via))\b")),
    ("mail", re.compile(r"^(?:email|e-mail|shoot \w+ an email|draft an? (?:email|mail|reply)|compose an? (?:email|mail))\b")),
    ("reminder", re.compile(r"^(?:remind me|set a reminder|make a reminder|don't let me forget|make sure i remember)\b")),
    ("notes", re.compile(r"^(?:create|make|start|take|add|write|new) (?:a |an )?(?:new )?note\b|^jot\b|^note to self\b")),
    ("calendar_create", re.compile(r"^(?:schedule|send (?:\w+ )?(?:a )?calendar invite|block (?:off|out)|book (?:a|an|me a) (?:meeting|call|slot|appointment)|set up a (?:\w+ )?(?:meeting|call)|add an? (?:event|meeting))\b")),
    ("type", re.compile(r"^type\b")),
    ("scroll", re.compile(r"^scroll\b")),
    ("music", re.compile(r"^(?:play|put on)\b(?!.*\b(?:video|this|that|it)\b)")),
]
# "open the home button", "select the download link": a UI noun at the end means a click, whatever
# other keywords the label contains.
UI_ELEMENT_CLICK_PATTERN = re.compile(
    r"^(?:click|tap|press|hit|toggle|select|choose|check|uncheck|push|open|focus)\s+(?:on\s+)?(?:the\s+)?(.+?)\s+(button|tab|link|checkbox|icon|toggle|switch|menu)$")
ANNOTATION_NOUN_PATTERN = re.compile(r"\b(annotations?|drawings?|markups?|circles?|arrows?|highlights?|overlay)\b")

# Ordered: the first matching pattern wins, so specific tools come before generic ones.
TOOL_CLAUSE_PATTERNS = [
    ("clear_annotations", re.compile(r"\b(clear|remove|erase|hide|get rid of|wipe)\b.*\b(annotations?|drawings?|markups?|circles?|arrows?|highlights?|overlay)\b")),
    ("draw_annotation", re.compile(r"\b(draw|circle|annotate|underline|point (?:to|at|out)|show me where|highlight the|put an arrow|mark the)\b")),
    ("record_flow", re.compile(r"\b(record|remember|save)\b.*\b(as (?:a |my )?(?:flow|workflow|routine|macro)|these steps|this flow|this workflow)\b")),
    ("shortcuts", re.compile(r"(?<!keyboard )\bshortcuts?\b")),
    ("run_flow", re.compile(r"\b(run|replay|do|start)\b.*\b(flow|workflow|routine)\b")),
    ("undo_last", re.compile(r"\b(undo|take that back|revert (?:that|the last|what you did)|reverse that)\b")),
    ("clipboard_read", re.compile(r"\b(?:what'?s|what is|read|check|tell me)\b.*\b(?:clipboard|pasteboard)\b|\bwhat did i (?:just )?copy\b|\bwhat's copied\b|\bwhat i copied\b")),
    ("window_snap", re.compile(r"\b(snap|tile|split ?screen|side by side|left half|right half|maximi[sz]e|full ?screen|move (?:this|the) window)\b")),
    ("scroll", re.compile(r"\b(scroll|page (?:up|down)|go (?:to )?(?:the )?(?:top|bottom) of)\b")),
    ("key", re.compile(r"\b(?:press|hit|use|do)\s+(?:the\s+)?(?:cmd|command|ctrl|control|option|alt|shift|escape|esc|enter|return|tab key|space ?bar|f\d{1,2})\b|\bkeyboard shortcut\b|\bcmd\s*(?:\+|plus|shift)?\s*\w\b")),
    ("double_click", re.compile(r"\bdouble[- ]?(?:click|tap)\b")),
    ("type", re.compile(r"\b(type|enter the text|write out|fill in|input the text)\b")),
    ("set_value", re.compile(r"\b(rewrite|rephrase|reword|proofread|shorten|make (?:this|it|that|the selection|the text|this paragraph) (?:more|less|shorter|longer|concise|formal|casual|friendlier|clearer)|fix (?:the )?(?:grammar|spelling|typos?)|replace (?:this|the selected|the selection))\b")),
    ("volume", re.compile(r"\b(volume|louder|quieter|unmute|mute|sound (?:up|down)|too loud|can't hear)\b")),
    ("brightness", re.compile(r"\b(brightness|brighter|dimmer|dim the screen|dim my screen|screen (?:is )?too (?:bright|dark))\b")),
    ("start_timer", re.compile(r"\b(timer|count ?down)\b")),
    ("reminder", re.compile(r"\b(remind|reminder|make sure i remember|don't let me forget)\b")),
    ("download_file", re.compile(r"^download\b|\bdownload (?:the |this |that |a )?(?:file|pdf|report|attachment|installer|image|zip|dmg)\b")),
    ("music", re.compile(r"\b(pause|resume|skip|next (?:song|track)|previous (?:song|track)|shuffle|unpause)\b|\bplay\b.*\b(music|song|songs|playlist|album|track|tunes|jazz|lofi|lo-fi|hip hop|rock|classical|liked songs|spotify|something)\b|^play\b(?!.*\b(?:video|movie|clip|game)\b)")),
    ("calendar_create", re.compile(r"\b(schedule|book|set up|add|create|put|block (?:off|out)|send (?:them |him |her )?(?:a )?calendar invite)\b.*\b(meeting|event|appointment|calendar|call|sync|1:1|one on one|lunch|invite)\b")),
    ("calendar", re.compile(r"\b(calendar|meetings?|appointments?|schedule|am i free|busy)\b|\b(?:what'?s|check|show|read)\b.*\bagenda\b")),
    ("things", re.compile(r"\b(things|to-?do(?: list)?|todo|task list|add a task)\b")),
    ("mail", re.compile(r"\b(e-?mail|mail)\b")),
    ("messages", re.compile(r"\b(text|imessage|message|sms|dm)\b")),
    ("notes", re.compile(r"\b(notes?|jot (?:down|this)|write (?:this )?down)\b")),
    ("finder", re.compile(r"\b(finder|reveal in|show in finder)\b|\b(?:open|show|go to)\b.*\b(downloads|desktop|documents|applications|home|pictures|movies)(?: folder)?\b")),
    ("open_url", re.compile(r"\b[a-z0-9-]+\.(?:com|org|net|io|dev|ai|edu|gov|co|me|app)\b|\bsearch (?:the web|google|online) for\b|\b(?:find|look up|search for) .+ (?:online|on google|on the web)\b|\bwebsite\b|\bin (?:safari|chrome|firefox|the browser|my browser)\b")),
    ("open_app", re.compile(r"\b(open|launch|start|bring up|fire up|switch to|pull up|go to|show me|get me)\b")),
    ("click", re.compile(r"\b(click|tap|press|hit|toggle|select|choose|check|uncheck|push)\b")),
]
COMPOSE_BODY_CUE_PATTERN = re.compile(r"\b(saying|that says|to say|telling|tell (?:him|her|them)|asking|about|that i|that we|that the|letting .* know|with the message)\b|:")
DEICTIC_TARGET_WORDS = {"it", "this", "that", "them", "these", "those", "one", "this one", "that one", "here", "there"}
ORDINAL_INDEX_BY_WORD = {"first": 0, "second": 1, "third": 2, "fourth": 3, "fifth": 4, "top": 0, "last": -1, "bottom": -1}
ROLE_BY_NOUN = {"button": "button", "tab": "tab", "link": "link", "checkbox": "checkbox", "box": "checkbox",
                "option": "option", "icon": "button", "toggle": "checkbox", "switch": "checkbox", "menu": "menu_item",
                "result": "link", "email": "email_row", "message": "row", "file": "row", "item": "row",
                "row": "row", "field": "text_field", "video": "video_card"}
MULTI_STEP_CLAUSE_SPLIT_PATTERN = re.compile(
    r"\s*,?\s*\b(?:and then|then|after that|afterwards|and also|also|and finally|finally)\b\s*|\s*;\s*")
COMMAND_VERB_ALTERNATION = (
    "open|launch|play|set|create|send|text|email|type|click|press|scroll|snap|turn|check|search|go|find|add|"
    "remind|make|move|rename|duplicate|show|start|take|copy|paste|select|close|draw|run|record|download|"
    "compose|write|reply|forward|attach|save|pause|skip|mute|unmute|draft|tap|hit|put|schedule|book|look|"
    "read|review|share|archive|print|sort|zip|compress|navigate|lower|raise|increase|decrease|dim|resume|stop|"
    "cancel|delete|remove|empty|buy|pay|submit|fill|log|sign|enter|use|drag|minimize|quit|visit|load|pull|"
    "bring|fire|switch|tell|message|block|clear|highlight|circle|point|undo|maximize|tile|summarize|translate")


TOOL_PATTERN_BY_NAME = dict(TOOL_CLAUSE_PATTERNS)


def resolved_app_name(raw_app_phrase):
    phrase = raw_app_phrase.strip().lower()
    phrase = re.sub(r"^(?:the|my|up)\s+", "", phrase)
    phrase = re.sub(r"\s+(?:app|application|window)$", "", phrase)
    return APP_NAME_BY_LOWERCASE.get(phrase)


def resolved_website_domain(raw_site_phrase):
    phrase = raw_site_phrase.strip().lower()
    phrase = re.sub(r"^(?:the website|website|the site|site|the|my)\s+", "", phrase)
    phrase = re.sub(r"\s+(?:website|site|page|in (?:safari|chrome|firefox|the browser|my browser))$", "", phrase)
    domain_match = re.search(r"\b([a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:com|org|net|io|dev|ai|edu|gov|co|me|app))\b", phrase)
    if domain_match:
        return domain_match.group(1)
    return KNOWN_WEBSITE_DOMAINS.get(phrase)


def extract_click_target_reference(clause_text):
    """Returns ("label", text, role) / ("ordinal", index, role) / ("deictic", None, None) / None."""
    target_match = re.search(
        r"\b(?:click|tap|press|hit|toggle|select|choose|check|uncheck|push)\s+(?:on\s+)?(?:the\s+|that\s+|this\s+)?(.+)$",
        clause_text)
    if not target_match:
        return None
    target_phrase = re.sub(r"\s+(?:on (?:the )?screen|here|now)$", "", target_match.group(1).strip())
    if target_phrase in DEICTIC_TARGET_WORDS:
        return ("deictic", None, "button")
    ordinal_match = re.match(r"^(first|second|third|fourth|fifth|top|last|bottom)\s+(\w+)$", target_phrase)
    if ordinal_match:
        role = ROLE_BY_NOUN.get(ordinal_match.group(2).rstrip("s"), "row")
        return ("ordinal", ORDINAL_INDEX_BY_WORD[ordinal_match.group(1)], role)
    role = "button"
    noun_match = re.match(r"^(.+?)\s+(button|tab|link|checkbox|box|option|icon|toggle|switch|menu)$", target_phrase)
    if noun_match:
        target_phrase, role = noun_match.group(1), ROLE_BY_NOUN[noun_match.group(2)]
    target_words = target_phrase.split()
    if not 1 <= len(target_words) <= 4 or set(target_words) & {"it", "this", "that", "and", "then", "them"}:
        return None
    if target_phrase in ROLE_BY_NOUN:
        return ("deictic", None, ROLE_BY_NOUN[target_phrase])
    return ("label", " ".join(word.capitalize() for word in target_words), role)


def map_clause_to_route(clause_text):
    """One command clause → ("destructive", None) | ("compose", tool) | ("click", reference) | ("tool", tool) | None."""
    command_text = strip_conversational_fillers(clause_text)
    if not command_text:
        return None
    is_annotation_clear = bool(ANNOTATION_NOUN_PATTERN.search(command_text))
    if UNSUPPORTED_CLAUSE_PATTERN.search(command_text):
        return None
    starts_with_content_verb = bool(CONTENT_CREATING_LEADING_VERB_PATTERN.match(command_text))
    if DESTRUCTIVE_REQUEST_PATTERN.search(command_text) and not is_annotation_clear and not starts_with_content_verb:
        return ("destructive", None)
    if RETRIEVAL_LEADING_VERB_PATTERN.match(command_text) and not TOOL_PATTERN_BY_NAME["open_url"].search(command_text):
        return None
    if KEYBOARD_LEADING_PATTERN.match(command_text):
        return ("tool", "key")
    plain_open_match = re.match(r"^(?:open|launch|start|switch to|bring up|fire up|pull up)\s+(?:up\s+)?(.+)$", command_text)
    if plain_open_match and resolved_app_name(plain_open_match.group(1)):
        return ("tool_with_app", ("open_app", resolved_app_name(plain_open_match.group(1))))
    ui_click_match = UI_ELEMENT_CLICK_PATTERN.match(command_text)
    if ui_click_match and len(ui_click_match.group(1).split()) <= 3:
        target_text = ui_click_match.group(1)
        role = ROLE_BY_NOUN[ui_click_match.group(2)]
        if target_text in DEICTIC_TARGET_WORDS or target_text in {"the", "a", "an"}:
            # "hit the checkbox" names only the element type: ambiguous unless exactly one exists.
            return ("click", ("deictic", None, role))
        ordinal_match = re.match(r"^(first|second|third|fourth|fifth|top|last|bottom)$", target_text)
        if ordinal_match:
            return ("click", ("ordinal", ORDINAL_INDEX_BY_WORD[target_text], role))
        return ("click", ("label", " ".join(word.capitalize() for word in target_text.split()), role))
    leading_tool_name = next((tool_name for tool_name, leading_pattern in LEADING_VERB_TOOL_PATTERNS
                              if leading_pattern.match(command_text)), None)
    if leading_tool_name is None and CLICK_LEADING_VERB_PATTERN.match(command_text):
        leading_tool_name = "click"
    ordered_patterns = ([(leading_tool_name, re.compile(""))] if leading_tool_name else []) + TOOL_CLAUSE_PATTERNS
    for tool_name, clause_pattern in ordered_patterns:
        if not clause_pattern.search(command_text):
            continue
        if tool_name in ("mail", "messages", "notes"):
            if re.match(r"^(?:find|search|look for|read|check|show|forward|reply to the|move|archive|attach)\b", command_text):
                return None  # retrieval/triage of existing mail or messages: no single Pace tool fits
            if COMPOSE_BODY_CUE_PATTERN.search(command_text) and len(command_text.split()) >= 5:
                return ("compose", tool_name)
            # "text kate let me check" / "message mike on my way": recipient followed by the body.
            if tool_name == "messages" and leading_tool_name == "messages" and len(command_text.split()) >= 4:
                return ("compose", "messages")
            if tool_name == "notes" and re.search(r"\b(take|make|write|jot|create|add)\b", command_text):
                return ("compose", "notes")
            if re.match(r"^(?:open|launch|check|show|go to|pull up|switch to)\b", command_text) and not re.search(r"\b(send|write|draft|compose)\b", command_text):
                app_name = {"mail": "Mail", "messages": "Messages", "notes": "Notes"}[tool_name]
                return ("tool_with_app", ("open_app", app_name))
            return ("tool", tool_name)
        if tool_name == "open_app":
            open_match = re.search(r"\b(?:open|launch|start|bring up|fire up|switch to|pull up|go to|show me|get me)\s+(?:up\s+)?(.+)$", command_text)
            if not open_match:
                return None
            target_phrase = open_match.group(1)
            app_name = resolved_app_name(target_phrase)
            if app_name:
                return ("tool_with_app", ("open_app", app_name))
            website_domain = resolved_website_domain(target_phrase)
            if website_domain:
                return ("tool_with_url", ("open_url", website_domain))
            return None
        if tool_name == "click":
            click_reference = extract_click_target_reference(command_text)
            if click_reference is None:
                return None
            return ("click", click_reference)
        return ("tool", tool_name)
    return None


def split_request_into_clauses(request_text):
    rough_clauses = [part.strip(" ,") for part in MULTI_STEP_CLAUSE_SPLIT_PATTERN.split(request_text.lower()) if part.strip(" ,")]
    clauses = []
    for rough_clause in rough_clauses:
        # Split on "and" only when the right side starts a new command ("open slack and check mentions").
        and_parts = re.split(r"\s+and\s+(?=(?:" + COMMAND_VERB_ALTERNATION + r")\b)", rough_clause)
        clauses.extend(part.strip(" ,") for part in and_parts if part.strip(" ,"))
    return clauses


# ================================================================ source loading

class PhrasingCandidate(dict):
    """text, source, source_intent, route (pool name), route_detail, core_key, split, clause_routes."""


def snapshot_files(dataset_directory_name, relative_glob):
    return sorted(glob.glob(str(HUGGING_FACE_HUB_DIRECTORY / dataset_directory_name / "snapshots" / "*" / relative_glob)))


def route_from_clauses(request_text):
    """Maps a free-form command request to a pool. Multi-clause requests become multi-step plans."""
    if SELF_CORRECTION_PATTERN.search(request_text.lower()):
        return None
    command_text = INTERNAL_FILLER_PATTERN.sub("", strip_conversational_fillers(request_text))
    clauses = split_request_into_clauses(command_text)
    if not clauses:
        return None
    clause_routes = [map_clause_to_route(clause) for clause in clauses]
    if any(route is None for route in clause_routes):
        return None
    # A leftover "and" inside a clause usually hides a second action the parser could not split
    # ("open mail and read the latest email"); a plan that silently drops it would mark DONE too early.
    # Content-carrying tools are exempt: "remind me to buy milk and eggs" is one action.
    content_carrying_tools = {"window_snap", "reminder", "calendar_create", "things", "type", "notes", "mail", "messages", "start_timer"}
    if any(re.search(r"\band\b", clause) and route[0] != "compose" and not (route[0] == "tool" and route[1] in content_carrying_tools)
           for clause, route in zip(clauses, clause_routes)):
        return None
    if len(clause_routes) == 1:
        route_kind, route_detail = clause_routes[0]
        if route_kind == "destructive":
            return ("destructive", None, None)
        if route_kind == "compose":
            return ("compose", route_detail, None)
        if route_kind == "click":
            reference_kind = route_detail[0]
            if reference_kind == "deictic":
                return ("ambiguous_reference", route_detail, None)
            return ("click_reference", route_detail, None)
        if route_kind in ("tool_with_app", "tool_with_url"):
            return ("tool", route_detail[0], route_detail[1])
        return ("tool", route_detail, None)
    if len(clause_routes) > 4:
        return None
    # A destructive clause may only appear as the last step (the plan stops there to ask).
    if any(route_kind == "destructive" for route_kind, _ in clause_routes[:-1]):
        return None
    if any(route_kind == "click" and route_detail[0] == "deictic" for route_kind, route_detail in clause_routes):
        return None
    return ("multi_step", list(zip(clauses, clause_routes)), None)


MASSIVE_INTENT_ROUTES = {
    "audio_volume_up": ("tool", "volume"), "audio_volume_down": ("tool", "volume"), "audio_volume_mute": ("tool", "volume"),
    "calendar_query": ("tool", "calendar"), "calendar_remove": ("destructive", None),
    "lists_remove": ("destructive", None), "email_sendemail": ("compose", "mail"),
    "play_music": ("tool", "music"), "music_settings": ("tool", "music"),
}
MASSIVE_RESPOND_INTENT_PREFIXES = ("qa_", "weather_", "news_", "datetime_", "recommendation_", "cooking_", "general_",
                                   "iot_", "takeaway_")
MASSIVE_RESPOND_INTENTS = {"transport_query", "transport_traffic", "transport_taxi", "transport_ticket", "social_query",
                           "email_addcontact", "email_querycontact", "play_game"}

OVOS_INTENT_ROUTES = {
    "calendar:create_event": ("tool", "calendar_create"), "calendar:list_events": ("tool", "calendar"),
    "calendar:next_event": ("tool", "calendar"), "calendar:cancel_event": ("destructive", None),
    "communication:send_message": ("compose", "messages"), "media:play_song": ("tool", "music"),
    "media:pause_playback": ("tool", "music"), "media:resume_playback": ("tool", "music"),
    "media:skip_track": ("tool", "music"), "media:set_volume": ("tool", "volume"),
    "system_control:mute_system": ("tool", "volume"), "system_control:set_brightness_screen": ("tool", "brightness"),
    "timers_alarms:set_timer": ("tool", "start_timer"),
}
OVOS_RESPOND_INTENT_PREFIXES = ("search_qa:", "weather:", "news:", "navigation:", "smarthome:")
OVOS_RESPOND_INTENTS = {"communication:call_contact", "communication:video_call", "communication:hang_up",
                        "system_control:change_language", "None"}


# MASSIVE has some label noise ("where is the car" under audio_volume_mute). Hardware-control rows must
# at least mention the thing they control.
MASSIVE_REQUIRED_KEYWORD_BY_TOOL = {
    "volume": re.compile(r"volume|loud|quiet|mute|sound|speaker|audio|silen|hear|noise|turn (?:it )?(?:up|down)"),
    "music": re.compile(r"play|song|music|track|album|playlist|shuffle|repeat|skip|pause|resume|listen|tune"),
}


def route_for_massive_intent(intent_name, utterance_text):
    if intent_name == "calendar_set":
        return ("tool", "reminder" if "remind" in utterance_text else "calendar_create")
    if intent_name == "lists_createoradd":
        return ("tool", "reminder" if "remind" in utterance_text else "things")
    if intent_name in MASSIVE_INTENT_ROUTES:
        route = MASSIVE_INTENT_ROUTES[intent_name]
        required_keyword_pattern = MASSIVE_REQUIRED_KEYWORD_BY_TOOL.get(route[1])
        if required_keyword_pattern and not required_keyword_pattern.search(utterance_text):
            return None
        return route
    if intent_name.startswith(MASSIVE_RESPOND_INTENT_PREFIXES) or intent_name in MASSIVE_RESPOND_INTENTS:
        return ("out_of_scope", None)
    return None


def route_for_ovos_intent(intent_name):
    if intent_name in OVOS_INTENT_ROUTES:
        return OVOS_INTENT_ROUTES[intent_name]
    if intent_name.startswith(OVOS_RESPOND_INTENT_PREFIXES) or intent_name in OVOS_RESPOND_INTENTS:
        return ("out_of_scope", None)
    return None


def text_matches_any_pace_action(request_text):
    command_text = strip_conversational_fillers(request_text)
    if DESTRUCTIVE_REQUEST_PATTERN.search(command_text):
        return True
    return any(clause_pattern.search(command_text) for tool_name, clause_pattern in TOOL_CLAUSE_PATTERNS
               if tool_name not in ("open_app", "click"))


def load_raw_source_rows():
    """Yields (text, source, source_intent, route_tuple) for every mappable row; logs what was skipped."""
    source_notes = {}
    raw_rows = []

    intent_corpus_files = sorted(INTENT_CORPUS_DIRECTORY.glob("*.jsonl"))
    for corpus_path in intent_corpus_files:
        source_name = f"intent-corpus/{corpus_path.stem}"
        for line in corpus_path.read_text().splitlines():
            if not line.strip():
                continue
            corpus_row = json.loads(line)
            transcript_text, intent_name = corpus_row.get("transcript", ""), corpus_row.get("intent", "")
            if intent_name == "screenAction":
                route = route_from_clauses(transcript_text)
            elif intent_name == "screenDescription":
                route = ("describe_screen", None, None)
            elif intent_name in ("pureKnowledge", "research", "chitchat"):
                route = ("out_of_scope", None, None)
            elif intent_name == "unknown":
                route = None if text_matches_any_pace_action(transcript_text) else ("out_of_scope", None, None)
            else:
                route = None
            if route:
                raw_rows.append((transcript_text, source_name, intent_name, route))
    source_notes["intent-corpus"] = f"{len(intent_corpus_files)} files"

    massive_files = snapshot_files("datasets--SetFit--amazon_massive_intent_en-US", "*.jsonl")
    for massive_path in massive_files:
        for line in Path(massive_path).read_text().splitlines():
            massive_row = json.loads(line)
            route = route_for_massive_intent(massive_row["label_text"], massive_row["text"])
            if route:
                raw_rows.append((massive_row["text"], "massive-en", massive_row["label_text"], (route[0], route[1], None)))
    source_notes["massive-en"] = f"{len(massive_files)} files" if massive_files else "not cached"

    ovos_files = snapshot_files("datasets--OpenVoiceOS--intents-for-eval", "en-US/*.jsonl")
    for ovos_path in ovos_files:
        for line in Path(ovos_path).read_text().splitlines():
            ovos_row = json.loads(line)
            intent_name = str(ovos_row.get("expected_intent"))
            route = route_for_ovos_intent(intent_name)
            if route:
                raw_rows.append((ovos_row["utterance"], "ovos-intents", intent_name, (route[0], route[1], None)))
    source_notes["ovos-intents"] = f"{len(ovos_files)} files" if ovos_files else "not cached"

    toolace_files = snapshot_files("datasets--Team-ACE--ToolACE", "data.json")
    for toolace_path in toolace_files:
        for conversation in json.loads(Path(toolace_path).read_text()):
            first_turn_text = conversation["conversations"][0]["value"].strip()
            word_count = len(first_turn_text.split())
            if "\n" in first_turn_text or not 5 <= word_count <= 30 or "role definition" in first_turn_text.lower():
                continue
            if text_matches_any_pace_action(first_turn_text):
                continue
            raw_rows.append((first_turn_text, "toolace", "external_api_request", ("out_of_scope", None, None)))
    source_notes["toolace"] = f"{len(toolace_files)} files" if toolace_files else "not cached"

    clinc_parquet_files = snapshot_files("datasets--clinc--clinc_oos", "*/*.parquet")
    source_notes["clinc-oos"] = (f"SKIPPED: {len(clinc_parquet_files)} parquet files need pyarrow (not installed)"
                                 if clinc_parquet_files else "not cached")
    source_notes["amazonscience-massive"] = "SKIPPED: only the loader script is cached, no data"
    source_notes["xlam-function-calling-60k"] = "SKIPPED: only README is cached, no data"
    return raw_rows, source_notes


def build_phrasing_pools(seed, fixture_exclusion_index):
    """Pools are keyed by route name ("tool:volume", "out_of_scope", ...). Each candidate carries its split."""
    raw_rows, source_notes = load_raw_source_rows()
    random.Random(seed).shuffle(raw_rows)
    phrasing_pools = collections.defaultdict(list)
    seen_core_keys = set()
    candidate_count_by_pool_and_skeleton = collections.Counter()
    excluded_fixture_near_duplicate_count = 0
    dropped_over_skeleton_cap_count = 0
    for request_text, source_name, source_intent, (route_kind, route_detail, route_argument) in raw_rows:
        request_text = re.sub(r"\s+", " ", request_text).strip()
        core_key = core_phrasing_key(request_text)
        if not core_key or core_key in seen_core_keys:
            continue
        seen_core_keys.add(core_key)
        if fixture_exclusion_index.contains_near_duplicate(core_key):
            excluded_fixture_near_duplicate_count += 1
            continue
        if route_kind == "tool":
            pool_name = f"tool:{route_detail}"
        elif route_kind == "compose":
            pool_name = f"compose:{route_detail}"
        else:
            pool_name = route_kind
        skeleton_key = phrasing_skeleton_key(core_key)
        if candidate_count_by_pool_and_skeleton[(pool_name, skeleton_key)] >= MAX_CANDIDATES_PER_PHRASING_SKELETON:
            dropped_over_skeleton_cap_count += 1
            continue
        candidate_count_by_pool_and_skeleton[(pool_name, skeleton_key)] += 1
        phrasing_pools[pool_name].append(PhrasingCandidate(
            text=request_text, source=source_name, source_intent=source_intent, route_detail=route_detail,
            route_argument=route_argument, core_key=core_key, split=split_for_core_key(skeleton_key, seed)))
    source_notes["excluded_as_fixture_near_duplicates"] = excluded_fixture_near_duplicate_count
    source_notes["dropped_over_per_skeleton_cap"] = dropped_over_skeleton_cap_count
    source_notes["max_candidates_per_phrasing_skeleton"] = MAX_CANDIDATES_PER_PHRASING_SKELETON
    return phrasing_pools, source_notes


class SourceBalancedPool:
    """Draws phrasings without replacement (reshuffling when exhausted), choosing the source family first
    with sqrt-size weighting so a 100k-row corpus does not drown a 300-row one."""

    def __init__(self, candidates, random_generator):
        self.random_generator = random_generator
        candidates_by_family = collections.defaultdict(list)
        for candidate in candidates:
            candidates_by_family[candidate["source"].split("/")[0]].append(candidate)
        self.family_names = sorted(candidates_by_family)
        self.family_weights = [math.sqrt(len(candidates_by_family[name])) for name in self.family_names]
        self.remaining_by_family = {}
        self.all_by_family = candidates_by_family
        for family_name in self.family_names:
            self._refill(family_name)

    def _refill(self, family_name):
        refilled = list(self.all_by_family[family_name])
        self.random_generator.shuffle(refilled)
        self.remaining_by_family[family_name] = refilled

    def __len__(self):
        return sum(len(candidates) for candidates in self.all_by_family.values())

    def draw(self):
        if not self.family_names:
            return None
        family_name = self.random_generator.choices(self.family_names, weights=self.family_weights)[0]
        if not self.remaining_by_family[family_name]:
            self._refill(family_name)
        return self.remaining_by_family[family_name].pop()


# ================================================================ template phrasings (fallback only)

# Used for tools the real corpora barely cover. Slots: {app} {site} {text} {key} {direction} {duration}
# {label} {title} {person} {folder} {shortcut} {flow} {file} {position}
TEMPLATE_PHRASINGS_BY_TOOL = {
    "type": ["type {text}", "write {text} in there", "enter {text}", "put {text} in the box", "fill in {text}",
             "can you type out {text}", "type in '{text}' for me", "go ahead and type {text}", "input {text}",
             "just write {text}", "type the words {text}", "key in {text}"],
    "set_value": ["make this more concise", "rewrite the selected text to sound friendlier", "clean up this paragraph",
                  "fix the typos in what I highlighted", "make the selection more formal", "shorten this",
                  "rephrase this so it's less passive aggressive", "turn this into bullet points",
                  "tighten up the highlighted sentence", "make this sound more professional",
                  "can you reword what's selected", "punch up this headline"],
    "undo_last": ["undo that", "undo", "take that back", "oops, revert that", "nope, undo the last thing",
                  "go back one step", "reverse what you just did", "cmd z that", "that was wrong, undo it",
                  "undo the last change", "can you undo", "put it back how it was"],
    "key": ["press {key}", "hit {key}", "do {key}", "use the shortcut {key}", "press the {key} keys",
            "send the keystroke {key}", "{key} please", "trigger {key}", "tap {key} on the keyboard",
            "hit return", "press escape", "press enter"],
    "clipboard_read": ["what's on my clipboard", "read me my clipboard", "what did I just copy",
                       "tell me what I copied", "what's in the clipboard right now", "read back what I copied",
                       "what text is on the pasteboard", "remind me what I copied a second ago",
                       "check my clipboard", "what's copied"],
    "window_snap": ["snap this window to the {position}", "put this window on the {position} half",
                    "move the window to the {position}", "tile this to the {position}", "maximize this window",
                    "make this window full screen", "dock this window {position}", "throw this on the {position} side",
                    "split this window to the {position}", "make the window fill the screen"],
    "scroll": ["scroll {direction}", "scroll {direction} a bit", "go {direction} a little", "page {direction}",
               "scroll way {direction}", "move the page {direction}", "keep scrolling {direction}",
               "scroll to the bottom", "go back to the top", "scroll {direction} some more", "show me more below"],
    "open_app": ["open {app}", "launch {app}", "bring up {app}", "fire up {app}", "switch to {app}",
                 "get {app} open", "start {app}", "pull up {app}", "can I get {app}", "I need {app}",
                 "jump into {app}", "{app} please"],
    "open_url": ["go to {site}", "open {site}", "pull up {site} in the browser", "load {site}",
                 "take me to {site}", "visit {site}", "navigate to {site}", "open {site} in Safari",
                 "bring up {site}", "head over to {site}"],
    "music": ["play some music", "pause the music", "skip this song", "next track", "resume playback",
              "play {track}", "put on some jazz", "stop the song", "go back a song", "shuffle my library",
              "play something chill", "unpause"],
    "volume": ["turn the volume {direction}", "volume {direction}", "make it louder", "make it quieter",
               "mute the sound", "unmute", "bump the volume {direction} a little", "it's too loud",
               "I can't hear anything, turn it up", "set volume to half", "crank it", "lower the sound"],
    "brightness": ["turn the brightness {direction}", "make the screen brighter", "dim the screen",
                   "brightness {direction}", "screen's too bright", "it's too dark, brighten it",
                   "lower the display brightness", "max brightness", "turn the display {direction} a notch",
                   "make my screen dimmer"],
    "calendar": ["what's on my calendar today", "what do I have tomorrow", "am I free at 3",
                 "what's my next meeting", "show me this week's schedule", "do I have anything friday",
                 "when's my next call", "check my agenda", "what meetings do I have this afternoon",
                 "any events this weekend"],
    "calendar_create": ["add {title} to my calendar tomorrow at 3pm", "schedule {title} for friday at 10",
                        "put {title} on my calendar next tuesday", "book an hour for {title} on monday",
                        "create an event called {title} at noon", "block off 2 to 4 for {title}",
                        "set up a meeting with {person} thursday morning", "calendar {title} for 9am tomorrow",
                        "make a new event: {title}, wednesday 4pm", "I've got {title} at 6 tonight, add it"],
    "reminder": ["remind me to {title}", "set a reminder to {title}", "don't let me forget to {title}",
                 "remind me tomorrow to {title}", "make a reminder: {title}", "can you remind me to {title} at 5",
                 "I need a reminder to {title}", "ping me later to {title}", "add a reminder for {title}",
                 "remember to {title}, remind me tonight"],
    "finder": ["open my {folder} folder", "show me {folder}", "go to {folder} in Finder", "open {folder}",
               "take me to my {folder}", "pull up the {folder} folder", "reveal {file} in Finder",
               "show {file} in the Finder", "open Finder at {folder}", "browse my {folder}"],
    "notes": ["take a note: {text}", "make a note that {text}", "jot down {text}", "write down {text}",
              "new note: {text}", "add to my notes: {text}", "note to self, {text}",
              "save a note saying {text}", "create a note called ideas with {text}", "put {text} in my notes"],
    "mail": ["email {person} that I'll be late", "draft an email to {person} about {title}",
             "write {person} an email saying thanks for today", "compose a mail to {person}",
             "start an email to {person} asking about {title}", "shoot {person} an email about {title}",
             "write up an email to {person} with the agenda", "draft a reply to {person}",
             "email {person} the notes from today", "send {person} an email saying the deck is ready"],
    "things": ["add {title} to Things", "put {title} in my Things inbox", "new to-do: {title}",
               "add a task to {title}", "make a to-do for {title}", "throw {title} on my to-do list",
               "add {title} to my task list", "create a todo called {title}", "capture a task: {title}",
               "log {title} as a to-do"],
    "shortcuts": ["run my {shortcut} shortcut", "run the {shortcut} shortcut", "trigger {shortcut}",
                  "kick off the {shortcut} shortcut", "start my {shortcut} shortcut", "fire the {shortcut} shortcut",
                  "use my {shortcut} shortcut", "execute the shortcut called {shortcut}",
                  "can you do my {shortcut} shortcut", "launch shortcut {shortcut}"],
    "messages": ["text {person} that I'm on my way", "message {person}", "send {person} a text saying running late",
                 "iMessage {person} happy birthday", "open Messages with {person}", "text {person} back",
                 "write {person} a message about {title}", "shoot {person} a text", "tell {person} over text I'm here",
                 "message {person} asking if we're still on"],
    "download_file": ["download {site}/report.pdf", "save the file at {site}/files/{file}",
                      "grab the pdf from {site}/whitepaper.pdf", "download that installer from {site}/download",
                      "pull down {site}/data.csv", "fetch {file} from {site}", "download the attachment link {site}/q3.pdf",
                      "get me a copy of {site}/slides.key", "save {site}/image.png to my downloads",
                      "download the zip at {site}/release.zip"],
    "start_timer": ["set a {duration} timer", "timer for {duration}", "start a {duration} timer for {label}",
                    "{duration} timer please", "count down {duration}", "set a timer for {duration} for the {label}",
                    "give me a {duration} countdown", "start a {label} timer, {duration}",
                    "time {duration} for me", "can you time {duration}"],
    "record_flow": ["record this as my {flow}", "watch me and save this as {flow}", "remember these steps as {flow}",
                    "start recording a flow called {flow}", "learn how I do {flow}", "save what I'm about to do as {flow}",
                    "record a workflow named {flow}", "capture these steps, call it {flow}",
                    "teach mode: {flow}", "record my {flow} routine"],
    "run_flow": ["run my {flow} flow", "do the {flow} routine", "replay {flow}", "run {flow}",
                 "start my {flow} workflow", "do my {flow} thing again", "kick off the {flow} flow",
                 "repeat the {flow} steps", "play back {flow}", "run the {flow} recording"],
    "draw_annotation": ["circle the {label} button", "draw an arrow to {label}", "highlight {label} for me",
                        "point at {label}", "show me where {label} is", "where's the {label} button, circle it",
                        "mark {label} on the screen", "draw a box around {label}", "underline {label}",
                        "point out the {label} option"],
    "clear_annotations": ["clear the annotations", "remove the drawings", "get rid of the circles",
                          "clear the screen markup", "hide the arrows", "erase what you drew",
                          "take the highlights off", "clear all that", "remove the overlay", "wipe the annotations"],
    "click": ["click {label}", "click on {label}", "hit {label}", "press the {label} button", "tap {label}",
              "go ahead and click {label}", "select {label}", "choose {label}", "click where it says {label}",
              "push {label}", "smash that {label} button", "click the one that says {label}",
              "can you hit {label} for me", "{label}, click it", "activate {label}", "open the {label} tab"],
    "double_click": ["double click {label}", "double-click {label}", "double click on the {label} file",
                     "double tap {label}", "open {label} with a double click", "double click to open {label}",
                     "give {label} a double click", "double-click the {label} icon"],
}
DESCRIBE_SCREEN_TEMPLATES = ["what am I looking at", "describe this window", "read me the error message",
                             "what does this button do", "what's on screen", "summarize this page",
                             "what app is this", "explain this dialog", "what's the total on this page",
                             "who sent the top email", "what does the warning say", "read the first paragraph"]
DESTRUCTIVE_TEMPLATES = ["delete this email", "delete the selected files", "empty the trash", "send it",
                         "send the email now", "pay for the order", "erase the drive", "delete all my notes",
                         "remove these files permanently", "clear my browser history", "place the order",
                         "transfer $500 to {person}", "delete {file}", "trash everything in {folder}",
                         "unsubscribe me from all of these", "cancel my subscription", "submit the form",
                         "buy it now", "discard the draft", "delete the conversation with {person}",
                         "force quit {app}", "uninstall {app}", "wipe the desktop", "delete my meeting with {person}"]
OUT_OF_SCOPE_TEMPLATES = ["what's the capital of Australia", "tell me a joke", "how are you", "book me a flight to Tokyo",
                          "order a pizza", "call an uber", "what's 15% of 80", "who won the game last night",
                          "turn on the living room lights", "translate hello into Japanese"]


def fill_template_slots(template_text, random_generator):
    slot_values = {
        "app": random_generator.choice(KNOWN_APP_NAMES),
        "site": random_generator.choice(sorted(set(KNOWN_WEBSITE_DOMAINS.values()))),
        "text": random_generator.choice(SAMPLE_TYPED_TEXTS),
        "key": random_generator.choice(["cmd+s", "command shift t", "cmd+w", "control c", "option space",
                                        "cmd+shift+4", "cmd z", "command k", "escape", "cmd+tab"]),
        "direction": random_generator.choice(["up", "down"]),
        "duration": random_generator.choice(["5 minute", "10 minute", "25 minute", "90 second", "half hour", "2 minute"]),
        "label": random_generator.choice(["Save", "Share", "Settings", "Export", "Compose", "Search", "Downloads",
                                          "New Tab", "Reply", "Submit", "Sign In", "Filters", "Add to Cart"]),
        "title": random_generator.choice(REMINDER_TITLES),
        "person": random_generator.choice(PERSON_NAMES),
        "folder": random_generator.choice(["Downloads", "Desktop", "Documents", "Pictures", "Applications"]),
        "shortcut": random_generator.choice(SHORTCUT_NAMES),
        "flow": random_generator.choice(FLOW_NAMES),
        "file": random_generator.choice(FILE_NAMES),
        "position": random_generator.choice(["left", "right"]),
        "track": random_generator.choice(MUSIC_TRACK_NAMES),
    }
    return re.sub(r"\{(\w+)\}", lambda slot_match: slot_values[slot_match.group(1)], template_text), slot_values


# ================================================================ screens

SCREEN_SIZES = [(1440, 900), (1512, 982), (1728, 1117), (1920, 1080), (2560, 1440)]


def mail_screen_elements(random_generator):
    elements = [("email_row", f"{random_generator.choice(PERSON_NAMES)} - {subject}", "unread" if random_generator.random() < .4 else "")
                for subject in random_generator.sample(EMAIL_SUBJECTS, random_generator.randint(2, 5))]
    elements += [("button", label, "") for label in random_generator.sample(
        ["Reply", "Reply All", "Forward", "Archive", "Delete", "Compose", "Flag", "Move", "Junk"], random_generator.randint(2, 5))]
    elements.append(("text_field", "Search", "Search mail"))
    return elements


def browser_screen_elements(random_generator):
    elements = [("tab", title, "") for title in random_generator.sample(
        ["GitHub", "Inbox (3)", "YouTube", "Hacker News", "Google Docs", "Stack Overflow", "Jira Board", "Figma"], random_generator.randint(1, 4))]
    elements += [("link", label, "") for label in random_generator.sample(
        ["Sign In", "Pricing", "Documentation", "Read more", "Contact us", "Download", "Blog", "Careers", "Terms"], random_generator.randint(2, 4))]
    elements += [("button", label, "") for label in random_generator.sample(["Back", "Reload", "Share", "New Tab", "Subscribe", "Accept cookies"], random_generator.randint(1, 3))]
    elements.append(("text_field", "Address and Search", random_generator.choice(["", "github.com/pace", "google.com"])))
    return elements


def finder_screen_elements(random_generator):
    elements = [("row", file_name, random_generator.choice(["", "Modified today", "2.4 MB", "Yesterday"]))
                for file_name in random_generator.sample(FILE_NAMES, random_generator.randint(3, 6))]
    elements += [("row", folder_name, "sidebar") for folder_name in random_generator.sample(["Downloads", "Desktop", "Documents", "Applications", "Recents"], 2)]
    elements += [("button", label, "") for label in random_generator.sample(["New Folder", "Share", "View options", "Tags", "Back"], 2)]
    return elements


def chat_screen_elements(random_generator):
    elements = [("channel_name", channel, "") for channel in random_generator.sample(["#general", "#design", "#eng-standup", "#random", "#launch"], 3)]
    elements += [("row", f"{random_generator.choice(PERSON_NAMES)}: {text}", "") for text in random_generator.sample(
        ["can you review my PR?", "lunch?", "deploy is green", "see notes above", "meeting moved to 4"], 2)]
    elements += [("text_area", "Message", ""), ("button", "Send", ""), ("button", random_generator.choice(["Attach", "Emoji", "Huddle"]), "")]
    return elements


def notes_screen_elements(random_generator):
    elements = [("row", title, "") for title in random_generator.sample(["Groceries", "Ideas", "Meeting notes", "Trip packing", "Books to read"], 3)]
    elements += [("text_area", "Note body", random_generator.choice(["", "milk, eggs, coffee", "Q3 goals: ship router"])),
                 ("button", "New Note", ""), ("button", random_generator.choice(["Share", "Checklist", "Format"]), "")]
    return elements


def music_screen_elements(random_generator):
    elements = [("row", track, random_generator.choice(["3:21", "4:02", "2:58"])) for track in random_generator.sample(MUSIC_TRACK_NAMES, 3)]
    elements += [("button", label, "") for label in ["Previous", random_generator.choice(["Play", "Pause"]), "Next", "Shuffle"]]
    elements.append(("option", random_generator.choice(["Liked Songs", "Daily Mix 1", "Discover Weekly"]), "playlist"))
    return elements


def settings_screen_elements(random_generator):
    elements = [("option", label, "") for label in random_generator.sample(["Wi-Fi", "Bluetooth", "Displays", "Sound", "Battery", "Privacy & Security", "Notifications"], 4)]
    elements += [("checkbox", random_generator.choice(["Show battery percentage", "Automatically adjust brightness", "Night Shift"]), random_generator.choice(["on", "off"])),
                 ("button", random_generator.choice(["Apply", "Done", "Revert"]), "")]
    return elements


def checkout_screen_elements(random_generator):
    return [("static_text", f"Total ${random_generator.randint(12, 480)}.{random_generator.randint(10, 99)}", ""),
            ("text_field", "Card number", ""), ("text_field", "Promo code", ""),
            ("button", random_generator.choice(["Place order", "Pay now", "Buy now"]), ""),
            ("button", "Apply coupon", ""), ("link", "Back to cart", "")]


def dialog_screen_elements(random_generator):
    return [("static_text", random_generator.choice(["Do you want to save the changes?", "A file with this name already exists.",
                                                     "Update available", "Allow notifications?"]), ""),
            *[("button", label, "") for label in random_generator.sample(["Save", "Don't Save", "Cancel", "OK", "Replace", "Keep Both", "Later", "Allow"], 3)]]


def code_editor_screen_elements(random_generator):
    return [("tab", file_name, "") for file_name in random_generator.sample(["main.swift", "App.tsx", "router.py", "README.md", "package.json"], 2)] + [
        ("menu_item", random_generator.choice(["Run", "Build", "Debug"]), ""),
        ("static_text", random_generator.choice(["Build succeeded", "error: cannot find 'x' in scope", "3 warnings"]), ""),
        ("button", random_generator.choice(["Run", "Commit", "Open Terminal"]), "")]


def pull_request_screen_elements(random_generator):
    return [("pr_row", title, "") for title in random_generator.sample(
        ["Fix login redirect", "Add router eval", "Bump deps", "Refactor TTS queue", "Docs: setup guide"], 3)] + [
        ("button", label, "") for label in random_generator.sample(["Approve", "Merge pull request", "Request changes", "Close pull request", "Comment"], 2)]


SCREEN_BUILDERS_BY_APP = {
    "Mail": mail_screen_elements, "Safari": browser_screen_elements, "Chrome": browser_screen_elements,
    "Finder": finder_screen_elements, "Slack": chat_screen_elements, "Messages": chat_screen_elements,
    "Notes": notes_screen_elements, "Music": music_screen_elements, "Spotify": music_screen_elements,
    "System Settings": settings_screen_elements, "Checkout": checkout_screen_elements, "Dialog": dialog_screen_elements,
    "VS Code": code_editor_screen_elements, "Xcode": code_editor_screen_elements, "GitHub": pull_request_screen_elements,
}


def layout_screen_elements(element_specs, random_generator, include_dock=None):
    """Assigns ids and plausible coordinates. Dock icons sit along the bottom edge, everything else in
    the content area; elements are ordered top-to-bottom like an accessibility walk."""
    screen_width, screen_height = random_generator.choice(SCREEN_SIZES)
    if include_dock is None:
        include_dock = random_generator.random() < 0.45
    positioned = []
    for role, label, text in element_specs:
        positioned.append((role, random_generator.randint(60, screen_width - 60),
                           random_generator.randint(40, screen_height - 120), label, text))
    if include_dock:
        dock_apps = random_generator.sample(KNOWN_APP_NAMES[:30], random_generator.randint(3, 7))
        dock_y = screen_height - random_generator.randint(20, 40)
        dock_x_start = random_generator.randint(screen_width // 4, screen_width // 3)
        for dock_index, app_name in enumerate(dock_apps):
            positioned.append(("dock_icon", dock_x_start + dock_index * 64, dock_y, app_name, ""))
    positioned.sort(key=lambda element: (element[2] // 40, element[1]))
    return [{"id": element_index, "role": role, "x": x_coordinate, "y": y_coordinate, "label": label, "text": text}
            for element_index, (role, x_coordinate, y_coordinate, label, text) in enumerate(positioned)]


def random_screen(random_generator, app_name=None, extra_specs=(), allow_empty=True):
    if allow_empty and not extra_specs and random_generator.random() < 0.08:
        return []
    builder_app = app_name if app_name in SCREEN_BUILDERS_BY_APP else random_generator.choice(sorted(SCREEN_BUILDERS_BY_APP))
    element_specs = list(SCREEN_BUILDERS_BY_APP[builder_app](random_generator))
    extra_labels = {label.lower() for _, label, _ in extra_specs}
    element_specs = [spec for spec in element_specs if spec[1].lower() not in extra_labels]
    return layout_screen_elements(element_specs + list(extra_specs), random_generator)


# ================================================================ arguments + results for completed steps

def iso_event_start_and_end(random_generator):
    day = random_generator.randint(1, 28)
    start_hour = random_generator.randint(8, 17)
    return (f"2026-10-{day:02d}T{start_hour:02d}:00:00-07:00", f"2026-10-{day:02d}T{start_hour + 1:02d}:00:00-07:00")


NUMBER_WORD_VALUES = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
                      "nine": 9, "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30, "forty five": 45, "an": 1, "a": 1, "half an": 30}
TRAILING_TIME_PHRASE_PATTERN = re.compile(
    r"\s+(?:at \d|at noon|at midnight|on (?:mon|tue|wed|thu|fri|sat|sun|the \d)|by \d|by tomorrow|before i|after i|"
    r"in (?:\d|a |an |one|two|three|five|ten|twenty|thirty)|this (?:morning|afternoon|evening|week|weekend)|next \w+|tomorrow|tonight|"
    r"today|every \w+|when i)\b.*$")


def first_capture(pattern, text):
    content_match = re.search(pattern, text)
    return content_match.group(1).strip(" ,.?!") if content_match else None


def extract_request_content_slots(request_text):
    """Pulls the free-text slots a tool call would carry out of the request, so completed steps
    agree with what was asked ("set a timer for 5 minutes" → duration "5 minutes", not a random one).
    A DONE state whose arguments contradict the request would be a mislabelled training row."""
    text = INTERNAL_FILLER_PATTERN.sub("", strip_conversational_fillers(request_text or ""))
    slots = {}
    duration_match = re.search(r"\b(\d+|" + "|".join(NUMBER_WORD_VALUES) + r")\s*(second|sec|minute|min|hour|hr)s?\b", text)
    if duration_match:
        amount_text = duration_match.group(1)
        amount = int(amount_text) if amount_text.isdigit() else NUMBER_WORD_VALUES[amount_text]
        unit = {"sec": "second", "min": "minute", "hr": "hour"}.get(duration_match.group(2), duration_match.group(2))
        slots["duration"] = f"{amount} {unit}{'s' if amount != 1 else ''}"
    slots["timer_label"] = first_capture(r"\btimer for (?:the |my )?([a-z][a-z ]{1,20}?)(?:\s+for\b|$)", text) or \
        first_capture(r"\bfor (?:the |my )?([a-z][a-z ]{1,20})$", text)
    reminder_match = first_capture(r"\b(?:remind me|reminder|don't let me forget|make sure i remember)\s+(?:to|about|that|for)?\s*(.+)$", text)
    if reminder_match:
        slots["reminder_title"] = TRAILING_TIME_PHRASE_PATTERN.sub("", reminder_match) or reminder_match
    slots["called"] = first_capture(r"\b(?:called|named|titled|with (?:the )?title|with subject)\s+(?:the\s+)?(.+?)(?:\s+(?:then|and|at|on|for)\b.*)?$", text)
    slots["about"] = first_capture(r"\b(?:about|regarding|re)\s+(?:the\s+)?(.+?)(?:\s+(?:then|and)\b.*)?$", text)
    slots["body"] = first_capture(r"\b(?:saying|that says|to say|that|telling (?:him|her|them))\s+(.+)$", text) or first_capture(r":\s*(.+)$", text)
    recipient_pattern = r"((?:my |the )?[a-z]+(?: team| founder| department| manager| partner| group)?)"
    recipient = first_capture(r"^(?:text|message|imessage|email|e-mail|tell|shoot|write|send|ping|dm|reply to)\s+(?:a (?:text|message|email|mail|quick text) to |an email to |a message to |an? \w+ to )?(?:to\s+)?" + recipient_pattern + r"\b", text) \
        or first_capture(r"\b(?:email|message|text|note|reply|mail) to\s+" + recipient_pattern + r"\b", text)
    if recipient and recipient not in {"a", "an", "the", "my", "me", "it", "them", "that", "this"}:
        slots["recipient"] = recipient
    if slots.get("recipient") and not slots.get("body"):
        # "text kate let me check" → body is whatever follows the recipient.
        body_after_recipient = first_capture(r"^(?:text|message|imessage|tell|dm|send (?:a |an )?(?:message|text|imessage|quick text) to)\s+"
                                             + re.escape(slots["recipient"]) + r"\s+(.{3,})$", text)
        if body_after_recipient:
            slots["body"] = body_after_recipient
    slots["things_title"] = first_capture(r"^(?:add|put|throw)\s+(.+?)\s+(?:to|on|in)\s+(?:my\s+|the\s+)?(?:things|to-?do|todo|task|grocery|shopping|list)", text) or \
        first_capture(r"\b(?:add a task|new to-?do|make a to-?do|create a todo)(?: called| for| to)?\s*:?\s*(.+)$", text)
    slots["named_thing"] = first_capture(r"\b(?:run|start|kick off|trigger|replay|do|use|fire|execute|play back|repeat|record|save)\s+(?:my |the )?(.+?)\s+(?:shortcut|flow|workflow|routine|recording|steps)\b", text) or \
        first_capture(r"\b(?:as|called|named)\s+(?:my |the )?(.+)$", text)
    meeting_with_match = re.search(r"\b(meeting|call|lunch|sync|1:1|coffee|dinner)\s+with\s+((?:my |the )?[a-z]+)", text)
    slots["event_title"] = (f"{meeting_with_match.group(1).capitalize()} with {meeting_with_match.group(2)}" if meeting_with_match else
                            first_capture(r"\binvite for ([a-z ]+?)(?:\s+(?:next|this|on|at|tomorrow|tonight|in)\b.*)?$", text) or
                            first_capture(r"^(?:add|put|schedule|book|create|calendar|block off .+? for)\s+(?:a |an |the )?(.+?)\s+(?:to|on|in|for|at|from)\b", text))
    slots["shortcut_name"] = first_capture(r"\b(?:run|start|kick off|trigger|use|fire|execute|do|launch)\s+(?:my |the )?(?:shortcut (?:called )?)?(.+?)(?:\s+shortcut)?$", text) \
        if "shortcut" in text else None
    slots["object"] = first_capture(r"^(?:email|send|text|mail|forward)\s+[a-z]+\s+(?:a copy of\s+)?(?:the\s+)+(.+)$", text)
    slots["search_query"] = first_capture(r"\b(?:search (?:the web|google|online|the internet) for|google|look up|find|search for)\s+(.+?)(?:\s+(?:online|on google|on the web))?$", text)
    slots["file_name"] = first_capture(r"\b([\w.-]+\.(?:pdf|csv|zip|png|key|dmg|docx|numbers|heic|txt|svg|m4a|pages|jpg))\b", request_text.lower())
    slots["text"] = text
    return {slot_name: slot_value for slot_name, slot_value in slots.items() if slot_value}


def synthesize_arguments(tool_name, clause_text, screen_elements, random_generator, target_element=None, route_argument=None):
    clause_text = clause_text or ""
    request_slots = extract_request_content_slots(clause_text)
    if tool_name in ("click", "double_click"):
        if target_element is not None:
            return {"element_id": target_element["id"]}
        return {"x": random_generator.randint(100, 1400), "y": random_generator.randint(80, 850), "screen": 1}
    if tool_name == "type":
        typed_match = re.search(r"\b(?:type|enter|write|fill in|input)\s+(?:in\s+|out\s+)?['\"]?(.+?)['\"]?$", clause_text)
        return {"text": typed_match.group(1) if typed_match else random_generator.choice(SAMPLE_TYPED_TEXTS)}
    if tool_name == "set_value":
        return {"text": random_generator.choice(["Thanks for the quick turnaround.", "Let's meet Thursday at 2.",
                                                 "The release ships next week."]), "action": "selection"}
    if tool_name in ("undo_last", "clipboard_read", "clear_annotations"):
        return {}
    if tool_name == "key":
        key_match = re.search(r"\b((?:cmd|command|ctrl|control|option|alt|shift)(?:[\s+]+(?:cmd|command|ctrl|control|option|alt|shift))*[\s+]+\w+|escape|esc|enter|return|tab)\b", clause_text)
        key_text = key_match.group(1) if key_match else random_generator.choice(["cmd+s", "cmd+t", "return", "escape"])
        key_text = re.sub(r"\bcommand\b", "cmd", re.sub(r"\bcontrol\b", "ctrl", key_text))
        return {"key": re.sub(r"[\s+]+", "+", key_text)}
    if tool_name == "window_snap":
        position = "right" if "right" in clause_text else "maximize" if re.search(r"maxim|full", clause_text) else "left"
        return {"position": position}
    if tool_name == "scroll":
        return {"direction": "up" if re.search(r"\b(up|top)\b", clause_text) else "down", "amount": random_generator.choice([3, 5, 10])}
    if tool_name == "open_app":
        return {"app": route_argument or random_generator.choice(KNOWN_APP_NAMES)}
    if tool_name == "open_url":
        domain = route_argument or resolved_website_domain(clause_text)
        if not domain and re.search(r"\b[a-z0-9-]+\.(?:com|org|net|io|dev|ai|edu|gov|co|so)\b", clause_text):
            domain = re.search(r"\b((?:[a-z0-9-]+\.)+(?:com|org|net|io|dev|ai|edu|gov|co|so))\b", clause_text).group(1)
        if not domain and request_slots.get("search_query"):
            return {"url": "https://www.google.com/search?q=" + request_slots["search_query"].replace(" ", "+")}
        return {"url": f"https://{domain or random_generator.choice(sorted(set(KNOWN_WEBSITE_DOMAINS.values())))}"}
    if tool_name == "music":
        for command_word, command_name in (("pause", "pause"), ("stop", "pause"), ("skip", "next"), ("next", "next"),
                                           ("previous", "previous"), ("back", "previous"), ("shuffle", "shuffle")):
            if command_word in clause_text:
                return {"command": command_name}
        return {"command": "play"}
    if tool_name in ("volume", "brightness"):
        direction = "down" if re.search(r"\b(down|lower|quieter|dim|dimmer|mute|silence|silent|zero|off|minimum|too loud|too bright|softer|decrease|reduce)\b", clause_text) else "up"
        return {"direction": direction, "steps": random_generator.choice([1, 2, 3])}
    if tool_name == "calendar":
        return {"range": "tomorrow" if "tomorrow" in clause_text else "week" if "week" in clause_text else "today"}
    if tool_name == "calendar_create":
        start_time, end_time = iso_event_start_and_end(random_generator)
        event_title = (request_slots.get("called") or request_slots.get("event_title") or request_slots.get("reminder_title") or request_slots.get("about")
                       or random_generator.choice(["Design review", "1:1 with Priya", "Dentist", "Team sync", "Lunch"]))
        return {"title": event_title,
                "start": start_time, "end": end_time}
    if tool_name == "reminder":
        return {"title": request_slots.get("reminder_title") or random_generator.choice(REMINDER_TITLES)}
    if tool_name == "finder":
        folder_name = next((name for name in FOLDER_PATH_BY_NAME if name in clause_text), random_generator.choice(["downloads", "documents", "desktop"]))
        return {"path": FOLDER_PATH_BY_NAME[folder_name], "action": "open"}
    if tool_name == "notes":
        note_body = request_slots.get("body") or request_slots.get("about") or request_slots.get("text") or random_generator.choice(SAMPLE_TYPED_TEXTS)
        return {"action": "create", "title": (request_slots.get("called") or note_body)[:40], "body": note_body}
    if tool_name == "mail":
        recipient_name = request_slots.get("recipient") or random_generator.choice(PERSON_NAMES)
        topic = (request_slots.get("about") or request_slots.get("called") or request_slots.get("object")
                 or " ".join(request_slots.get("body", "").split()[:5]) or random_generator.choice(EMAIL_SUBJECTS))
        email_body = request_slots.get("body") or f"quick note about {topic}."
        return {"to": recipient_name, "subject": topic[:60].capitalize(), "body": f"Hi {recipient_name.split()[-1].capitalize()}, {email_body}"}
    if tool_name == "things":
        return {"title": request_slots.get("things_title") or request_slots.get("reminder_title") or random_generator.choice(REMINDER_TITLES), "notes": ""}
    if tool_name == "shortcuts":
        return {"name": (request_slots.get("shortcut_name") or random_generator.choice(SHORTCUT_NAMES)).title()}
    if tool_name == "messages":
        return {"recipient": request_slots.get("recipient") or random_generator.choice(PERSON_NAMES),
                "text": request_slots.get("body") or request_slots.get("about") or random_generator.choice(["on my way", "running 10 min late", "sounds good!"])}
    if tool_name == "download_file":
        url_match = re.search(r"\b((?:[a-z0-9-]+\.)+(?:com|org|net|io|dev|ai|edu|gov|co)(?:/[\w./-]*)?)", clause_text)
        if url_match and "/" in url_match.group(1):
            return {"url": f"https://{url_match.group(1)}", "name": url_match.group(1).rsplit("/", 1)[-1] or "download"}
        file_name = request_slots.get("file_name") or random_generator.choice(["report.pdf", "data.csv", "installer.dmg", "slides.key"])
        file_host = url_match.group(1) if url_match else random_generator.choice(['example.com', 'arxiv.org', 'github.com'])
        return {"url": f"https://{file_host}/{file_name}", "name": file_name}
    if tool_name == "start_timer":
        timer_arguments = {"duration": request_slots.get("duration") or random_generator.choice(["5 minutes", "10 minutes", "25 minutes"])}
        if request_slots.get("timer_label") and not re.search(r"\d|minute|second|hour", request_slots["timer_label"]):
            timer_arguments["label"] = request_slots["timer_label"]
        return timer_arguments
    if tool_name in ("record_flow", "run_flow"):
        return {"name": request_slots.get("named_thing") or random_generator.choice(FLOW_NAMES)}
    if tool_name == "draw_annotation":
        anchor = target_element or {"x": random_generator.randint(100, 1300), "y": random_generator.randint(80, 800), "label": "here"}
        return {"shapes": [{"kind": random_generator.choice(["circle", "rect", "arrow"]), "x": anchor["x"] - 40, "y": anchor["y"] - 20,
                            "width": 120, "height": 50, "color": "red", "label": anchor["label"]}], "screen": 1}
    return {}


def successful_result_text(tool_name, tool_arguments, screen_elements, random_generator):
    if tool_name in ("click", "double_click"):
        element = next((element for element in screen_elements if element["id"] == tool_arguments.get("element_id")), None)
        if element:
            return random_generator.choice([f"ok: clicked '{element['label']}'", f"ok: {tool_name.replace('_', ' ')} on {element['role']} '{element['label']}'"])
        return f"ok: clicked at {tool_arguments.get('x')},{tool_arguments.get('y')}"
    result_options = {
        "type": [f"ok: typed {len(str(tool_arguments.get('text', '')))} characters", "ok: text entered"],
        "set_value": ["ok: replaced the selection", "ok: selection updated"],
        "undo_last": ["ok: undid the last action", "ok: reverted"],
        "key": [f"ok: pressed {tool_arguments.get('key')}", "ok: keystroke sent"],
        "clipboard_read": ["ok: clipboard contains \"https://github.com/pace/pull/812\"", "ok: clipboard contains 214 characters of text", "ok: clipboard is empty"],
        "window_snap": [f"ok: window snapped {tool_arguments.get('position')}", "ok: window resized"],
        "scroll": [f"ok: scrolled {tool_arguments.get('direction')}", "ok: scrolled"],
        "open_app": [f"ok: {tool_arguments.get('app')} is now open and frontmost", f"ok: launched {tool_arguments.get('app')}"],
        "open_url": [f"ok: opened {tool_arguments.get('url')} in the browser", "ok: page loaded"],
        "music": [f"ok: music {tool_arguments.get('command')}", f"ok: now {'playing' if tool_arguments.get('command') == 'play' else tool_arguments.get('command')}"],
        "volume": [f"ok: volume {random_generator.randint(0, 100)}%", "ok: volume changed"],
        "brightness": [f"ok: brightness {random_generator.randint(10, 100)}%", "ok: brightness changed"],
        "calendar": ["ok: 3 events: 10:00 Standup, 13:00 Lunch with Sam, 16:00 Design review", "ok: no events", "ok: 1 event: 15:00 Dentist"],
        "calendar_create": [f"ok: created event '{tool_arguments.get('title')}'", "ok: event added to Calendar"],
        "reminder": [f"ok: reminder '{tool_arguments.get('title')}' created", "ok: added to Reminders"],
        "finder": [f"ok: opened {tool_arguments.get('path')} in Finder", "ok: Finder window opened"],
        "notes": ["ok: note created", f"ok: saved note '{tool_arguments.get('title')}'"],
        "mail": ["ok: draft created in Mail (not sent)", f"ok: compose window open, addressed to {tool_arguments.get('to')}"],
        "things": [f"ok: added '{tool_arguments.get('title')}' to Things inbox", "ok: to-do created"],
        "shortcuts": [f"ok: ran shortcut '{tool_arguments.get('name')}'", "ok: shortcut finished"],
        "messages": [f"ok: Messages open with {tool_arguments.get('recipient')}, draft ready (not sent)", "ok: message drafted"],
        "download_file": [f"ok: saved {tool_arguments.get('name')} to ~/Downloads", "ok: download complete"],
        "start_timer": [f"ok: {tool_arguments.get('duration')} timer started", "ok: timer running"],
        "record_flow": [f"ok: recording '{tool_arguments.get('name')}'", "ok: flow recording started"],
        "run_flow": [f"ok: ran flow '{tool_arguments.get('name')}' (4 steps)", "ok: flow finished"],
        "draw_annotation": ["ok: drew 1 shape", "ok: annotation shown"],
        "clear_annotations": ["ok: annotations cleared", "ok: overlay cleared"],
    }
    return random_generator.choice(result_options.get(tool_name, ["ok: done"]))


FAILURE_RESULT_TEXTS = ["error: element not found", "error: Accessibility permission denied", "error: timed out after 5s",
                        "error: no frontmost window", "error: the app did not respond", "error: action was blocked by the user",
                        "error: invalid arguments"]
FAILURE_RESULT_TEXTS_BY_TOOL = {
    "open_app": ["error: application not found", "error: app failed to launch"],
    "open_url": ["error: could not resolve host", "error: invalid URL"],
    "download_file": ["error: HTTP 404", "error: download was declined"],
    "shortcuts": ["error: no shortcut with that name"], "run_flow": ["error: no flow with that name"],
    "calendar_create": ["error: Calendar access not granted"], "reminder": ["error: Reminders access not granted"],
    "click": ["error: element is disabled", "error: element moved; no longer at that position"],
}


def failed_result_text(tool_name, random_generator):
    return random_generator.choice(FAILURE_RESULT_TEXTS_BY_TOOL.get(tool_name, []) + FAILURE_RESULT_TEXTS)


def completed_step(tool_name, tool_arguments, screen_elements, random_generator, failed=False):
    result_text = failed_result_text(tool_name, random_generator) if failed else successful_result_text(
        tool_name, tool_arguments, screen_elements, random_generator)
    return {"tool": tool_name, "args": tool_arguments, "result": result_text}


# ================================================================ scenario generators

class StepStateGenerator:
    def __init__(self, phrasing_pools, tool_names, seed, fixture_exclusion_index):
        self.random_generator = random.Random(seed)
        self.seed = seed
        self.tool_names = tool_names
        self.fixture_exclusion_index = fixture_exclusion_index
        self.pools = {pool_name: SourceBalancedPool(candidates, self.random_generator)
                      for pool_name, candidates in sorted(phrasing_pools.items())}
        self.template_family_counter = collections.Counter()

    # ---------------------------------------------------- phrasing helpers

    def template_candidate(self, template_family, templates):
        """Template fallback. The sealed split also gets whole templates it never shares with train
        (hash of family+template), so sealed tests unseen sentence structure, not just unseen slot values."""
        for _ in range(20):
            template_text = self.random_generator.choice(templates)
            request_text, slot_values = fill_template_slots(template_text, self.random_generator)
            core_key = core_phrasing_key(request_text)
            if self.fixture_exclusion_index.contains_near_duplicate(core_key):
                continue
            template_is_sealed_only = stable_unit_interval(f"template:{template_family}:{template_text}", self.seed) < SEALED_SPLIT_FRACTION
            split_name = "sealed" if template_is_sealed_only else split_for_core_key(core_key, self.seed)
            if not template_is_sealed_only and split_name == "sealed":
                # Keep train-template renderings in train so a sealed-only template stays the sealed signal.
                split_name = "train"
            return PhrasingCandidate(text=request_text, source="template", source_intent=template_family,
                                     route_detail=None, route_argument=None, core_key=core_key, split=split_name,
                                     slot_values=slot_values, source_intent_template=template_text)
        return None

    def draw_real_or_template(self, pool_name, template_family, templates, real_probability):
        pool = self.pools.get(pool_name)
        if pool is not None and len(pool) and self.random_generator.random() < real_probability:
            return pool.draw()
        return self.template_candidate(template_family, templates)

    def real_probability_for_pool(self, pool_name, expected_draws):
        # Reusing a real phrasing about twice (with a different screen/steps each time) is still better
        # than a template draw, so the real share scales with 2x the pool size.
        pool_size = len(self.pools[pool_name]) if pool_name in self.pools else 0
        return min(0.85, 2 * pool_size / max(1, expected_draws))

    def make_row(self, scenario, candidate, screen_elements, completed_steps, intended_label):
        return {"scenario": scenario, "request": candidate["text"], "screen_elements": screen_elements,
                "completed_steps": completed_steps, "intended_label": intended_label,
                "source": candidate["source"], "split": candidate["split"], "core_key": candidate["core_key"]}

    # ---------------------------------------------------- click helpers

    def screen_with_unique_target(self, target_label, target_role, app_name=None):
        target_spec = (target_role, target_label, "")
        screen_elements = random_screen(self.random_generator, app_name, extra_specs=[target_spec])
        target_element = next(element for element in screen_elements
                              if element["label"] == target_label and element["role"] == target_role)
        return screen_elements, target_element

    def screen_with_ordinal_target(self, ordinal_index, target_role):
        list_labels = {"link": ["Result: " + title for title in ["Getting started", "API reference", "Pricing", "FAQ", "Changelog"]],
                       "tab": ["GitHub", "Docs", "Inbox", "Calendar", "Figma"],
                       "email_row": [f"{name} - {subject}" for name, subject in zip(PERSON_NAMES, EMAIL_SUBJECTS)],
                       "video_card": ["How to cook rice", "Lofi beats", "Swift tutorial", "Travel vlog", "Keynote recap"]}
        labels = list_labels.get(target_role, FILE_NAMES)
        list_length = self.random_generator.randint(3, 5)
        chosen_labels = self.random_generator.sample(labels, list_length)
        screen_width, screen_height = self.random_generator.choice(SCREEN_SIZES)
        list_x = self.random_generator.randint(200, screen_width // 2)
        list_y = self.random_generator.randint(120, 300)
        vertical = target_role != "tab"
        screen_elements = []
        target_list_index = ordinal_index if ordinal_index >= 0 else list_length + ordinal_index
        for list_index, label in enumerate(chosen_labels):
            screen_elements.append({"id": list_index, "role": target_role,
                                    "x": list_x + (0 if vertical else list_index * 160),
                                    "y": list_y + (list_index * 56 if vertical else 0), "label": label, "text": ""})
        extra_specs = [("button", label, "") for label in self.random_generator.sample(["Back", "Filter", "Sort", "Share"], 2)]
        for extra_index, (role, label, text) in enumerate(extra_specs):
            screen_elements.append({"id": list_length + extra_index, "role": role, "x": self.random_generator.randint(60, screen_width - 60),
                                    "y": self.random_generator.randint(40, 100), "label": label, "text": text})
        return screen_elements, screen_elements[target_list_index]

    def click_state(self, prefer_double_click=False):
        """Returns (candidate, screen_elements, target_element, tool_name) with exactly one fitting element."""
        pool_name = "click_reference"
        use_real = (not prefer_double_click and pool_name in self.pools
                    and self.random_generator.random() < self.real_probability_for_pool(pool_name, 1500))
        if use_real:
            candidate = self.pools[pool_name].draw()
            reference_kind, reference_value, reference_role = candidate["route_detail"]
            if reference_kind == "ordinal":
                screen_elements, target_element = self.screen_with_ordinal_target(reference_value, reference_role)
            else:
                screen_elements, target_element = self.screen_with_unique_target(reference_value, reference_role)
            return candidate, screen_elements, target_element, "click"
        tool_name = "double_click" if prefer_double_click else "click"
        screen_elements = random_screen(self.random_generator, self.random_generator.choice(sorted(SCREEN_BUILDERS_BY_APP)), allow_empty=False)
        label_counts = collections.Counter(element["label"].lower() for element in screen_elements)
        unique_elements = [element for element in screen_elements if label_counts[element["label"].lower()] == 1
                           and (not prefer_double_click or element["role"] in ("row", "dock_icon", "email_row", "pr_row"))]
        if not unique_elements:
            return None
        target_element = self.random_generator.choice(unique_elements)
        candidate = self.template_candidate(tool_name, TEMPLATE_PHRASINGS_BY_TOOL[tool_name])
        if candidate is None:
            return None
        label_text = target_element["label"]
        candidate["text"] = candidate["text"].replace(candidate["slot_values"]["label"], label_text)
        candidate["core_key"] = core_phrasing_key(candidate["text"])
        return candidate, screen_elements, target_element, tool_name

    # ---------------------------------------------------- scenarios

    def single_tool_state(self, tool_name, rows_per_tool):
        """Request for one tool with nothing done yet. Returns (candidate, screen, target, tool) or None."""
        if tool_name in ("click", "double_click"):
            return self.click_state(prefer_double_click=(tool_name == "double_click"))
        if tool_name == "draw_annotation":
            candidate = self.draw_real_or_template("tool:draw_annotation", "draw_annotation",
                                                   TEMPLATE_PHRASINGS_BY_TOOL["draw_annotation"],
                                                   self.real_probability_for_pool("tool:draw_annotation", rows_per_tool) if "tool:draw_annotation" in self.pools else 0)
            if candidate is None:
                return None
            target_label = (candidate.get("slot_values") or {}).get("label") or annotation_target_label(candidate["text"])
            if target_label:
                screen_elements, target_element = self.screen_with_unique_target(target_label, "button")
            else:
                screen_elements = random_screen(self.random_generator, allow_empty=False)
                target_element = None
            return candidate, screen_elements, target_element, tool_name
        pool_name = f"tool:{tool_name}"
        real_probability = self.real_probability_for_pool(pool_name, rows_per_tool) if pool_name in self.pools else 0
        templates = TEMPLATE_PHRASINGS_BY_TOOL[tool_name] + [load_tool_catalog_example_utterance(tool_name)]
        candidate = self.draw_real_or_template(pool_name, tool_name, templates, real_probability)
        if candidate is None:
            return None
        template_slot_values = candidate.get("slot_values") or {}
        if candidate.get("route_argument") is None and tool_name == "open_app" and "{app}" in candidate.get("source_intent_template", ""):
            candidate["route_argument"] = template_slot_values.get("app")
        if candidate.get("route_argument") is None and tool_name == "open_url" and "{site}" in candidate.get("source_intent_template", ""):
            candidate["route_argument"] = template_slot_values.get("site")
        app_hint = {"type": self.random_generator.choice(["Notes", "Mail", "Safari", "Slack"]), "set_value": "Notes",
                    "scroll": "Safari", "music": "Spotify", "finder": "Finder"}.get(tool_name)
        screen_elements = random_screen(self.random_generator, app_hint)
        return candidate, screen_elements, None, tool_name

    def generate_single_tool_first_step(self, tool_name, rows_per_tool):
        state = self.single_tool_state(tool_name, rows_per_tool)
        if state is None:
            return None
        candidate, screen_elements, _, chosen_tool = state
        return self.make_row("single_tool_first_step", candidate, screen_elements, [], chosen_tool)

    def generate_click_unique_target(self):
        state = self.click_state(prefer_double_click=self.random_generator.random() < 0.15)
        if state is None:
            return None
        candidate, screen_elements, _, tool_name = state
        return self.make_row("click_unique_target", candidate, screen_elements, [], tool_name)

    AMBIGUOUS_TEMPLATE_GROUPS = [
        (["click the button", "press the button", "hit that button", "click it", "tap the button", "press it"],
         lambda generator: [("button", label, "") for label in generator.sample(["Save", "Cancel", "Submit", "Continue", "Done", "Apply"], generator.randint(2, 4))]),
        (["open the email", "open that email", "read the email", "open the message from work", "click the email"],
         lambda generator: [("email_row", f"{generator.choice(PERSON_NAMES)} - {subject}", "") for subject in generator.sample(EMAIL_SUBJECTS, generator.randint(2, 4))]),
        (["click save", "hit save", "press save", "save it with the button"],
         lambda generator: [("button", "Save", where) for where in generator.sample(["toolbar", "dialog", "sidebar", "footer"], generator.randint(2, 3))]),
        (["open the file", "open the pdf", "double click the document", "open the report"],
         lambda generator: [("row", name, "") for name in generator.sample(["Q3 report.pdf", "Q4 report.pdf", "report-final.pdf", "report-draft.pdf"], generator.randint(2, 4))]),
        (["click the link", "follow the link", "open that link", "click download"],
         lambda generator: [("link", "Download", where) for where in generator.sample(["macOS", "Windows", "Linux", "Source"], generator.randint(2, 4))]),
        (["reply to him", "reply to it", "answer that message", "respond to the message"],
         lambda generator: [("row", f"{name}: {text}", "") for name, text in zip(generator.sample(PERSON_NAMES, 3), ["you around?", "call me", "see doc"])][:generator.randint(2, 3)]),
        (["play the video", "play this", "watch that one", "start the video"],
         lambda generator: [("video_card", title, "") for title in generator.sample(["Swift tutorial", "Lofi beats", "Keynote recap", "Travel vlog"], generator.randint(2, 4))]),
        (["select the tab", "go to the other tab", "switch tabs", "click the tab"],
         lambda generator: [("tab", title, "") for title in generator.sample(["GitHub", "Docs", "Inbox", "Calendar", "Figma"], generator.randint(2, 4))]),
        (["merge the PR", "approve the pull request", "open the PR", "review the pull request"],
         lambda generator: [("pr_row", title, "") for title in generator.sample(["Fix login redirect", "Add router eval", "Bump deps", "Refactor TTS"], generator.randint(2, 4))]),
        (["open that app", "launch it", "open this one", "click the icon"],
         lambda generator: [("dock_icon", app, "") for app in generator.sample(KNOWN_APP_NAMES[:20], generator.randint(2, 4))]),
    ]

    def generate_ambiguous_targets(self):
        """2-4 plausible on-screen targets. Real deictic click requests ("click that") are used when available."""
        group_templates, build_specs = self.random_generator.choice(self.AMBIGUOUS_TEMPLATE_GROUPS)
        if "ambiguous_reference" in self.pools and self.random_generator.random() < 0.35:
            candidate = self.pools["ambiguous_reference"].draw()
            referenced_role = candidate["route_detail"][2] or "button"
            same_role_labels = {"button": ["Save", "Cancel", "Submit", "Continue", "Done"], "link": ["Docs", "Pricing", "Blog", "Download"],
                                "tab": ["GitHub", "Inbox", "Docs", "Figma"], "checkbox": ["Remember me", "Subscribe", "Agree to terms"],
                                "menu_item": ["File", "Edit", "View"], "option": ["Small", "Medium", "Large"]}.get(referenced_role, ["One", "Two", "Three"])
            ambiguous_specs = [(referenced_role, label, "") for label in
                               self.random_generator.sample(same_role_labels, min(len(same_role_labels), self.random_generator.randint(2, 4)))]
        else:
            candidate = self.template_candidate("ambiguous:" + group_templates[0], group_templates)
            ambiguous_specs = build_specs(self.random_generator) if candidate else None
        if candidate is None:
            return None
        screen_elements = layout_screen_elements(ambiguous_specs + [
            spec for spec in settings_screen_elements(self.random_generator)[:2]], self.random_generator, include_dock=False)
        return self.make_row("ambiguous_targets", candidate, screen_elements, [], "ASK_USER")

    def generate_destructive(self):
        candidate = self.draw_real_or_template("destructive", "destructive", DESTRUCTIVE_TEMPLATES,
                                               self.real_probability_for_pool("destructive", 1200) if "destructive" in self.pools else 0)
        if candidate is None:
            return None
        request_lower = candidate["text"].lower()
        if re.search(r"\b(pay|order|buy|purchase|checkout)\b", request_lower):
            app_name = "Checkout"
        elif re.search(r"\b(email|inbox|mail)\b", request_lower):
            app_name = "Mail"
        elif re.search(r"\b(file|folder|trash|downloads|desktop)\b", request_lower):
            app_name = "Finder"
        elif re.search(r"\b(send|message|text)\b", request_lower):
            app_name = "Messages"
        else:
            app_name = None
        destructive_extra_specs = [("button", self.random_generator.choice(["Delete", "Move to Trash", "Empty Trash", "Send", "Remove"]), "")] \
            if self.random_generator.random() < 0.5 else []
        screen_elements = random_screen(self.random_generator, app_name, extra_specs=destructive_extra_specs)
        completed_steps = []
        # Sometimes the preparatory step already happened (draft written, files selected).
        preparatory_tool_by_app = {"Mail": "mail", "Messages": "messages", "Finder": "finder", "Checkout": "open_url"}
        if app_name in preparatory_tool_by_app and self.random_generator.random() < 0.3:
            # The preparatory step already happened (draft written, folder open, checkout page loaded).
            preparatory_tool = preparatory_tool_by_app[app_name]
            preparatory_arguments = synthesize_arguments(preparatory_tool, request_lower, screen_elements, self.random_generator,
                                                         route_argument="shop.example.com" if preparatory_tool == "open_url" else None)
            completed_steps.append(completed_step(preparatory_tool, preparatory_arguments, screen_elements, self.random_generator))
        return self.make_row("destructive", candidate, screen_elements, completed_steps, "ASK_USER")

    def generate_out_of_scope(self):
        candidate = self.draw_real_or_template("out_of_scope", "out_of_scope", OUT_OF_SCOPE_TEMPLATES, 0.97)
        if candidate is None:
            return None
        return self.make_row("out_of_scope", candidate, random_screen(self.random_generator), [], "RESPOND")

    def generate_describe_screen(self):
        candidate = self.draw_real_or_template("describe_screen", "describe_screen", DESCRIBE_SCREEN_TEMPLATES, 0.9)
        if candidate is None:
            return None
        return self.make_row("describe_screen", candidate, random_screen(self.random_generator, allow_empty=False), [], "RESPOND")

    def compose_candidate(self):
        compose_tool = self.random_generator.choice(["mail", "mail", "messages", "notes"])
        pool_name = f"compose:{compose_tool}"
        candidate = self.draw_real_or_template(pool_name, f"compose:{compose_tool}", TEMPLATE_PHRASINGS_BY_TOOL[compose_tool],
                                               self.real_probability_for_pool(pool_name, 400) if pool_name in self.pools else 0)
        return candidate, compose_tool

    def generate_compose(self):
        candidate, compose_tool = self.compose_candidate()
        if candidate is None:
            return None
        app_name = {"mail": "Mail", "messages": "Messages", "notes": "Notes"}[compose_tool]
        completed_steps = []
        screen_elements = random_screen(self.random_generator, self.random_generator.choice([app_name, None]))
        if self.random_generator.random() < 0.25:
            # App already opened; the body still has to be written.
            open_arguments = {"app": app_name}
            completed_steps.append(completed_step("open_app", open_arguments, screen_elements, self.random_generator))
            screen_elements = random_screen(self.random_generator, app_name, allow_empty=False)
        return self.make_row("compose", candidate, screen_elements, completed_steps, compose_tool)

    # ---------------------------------------------------- multi-step plans

    TEMPLATE_PLANS = [
        (["open {app} and type {text}", "launch {app}, then type {text}", "get {app} up and write {text} in it"],
         lambda slots: [("open_app", "open", slots["app"]), ("type", "type " + slots["text"], None)]),
        (["open safari and go to {site}", "launch the browser then load {site}", "fire up safari and head to {site}"],
         lambda slots: [("open_app", "open", "Safari"), ("open_url", slots["site"], slots["site"])]),
        (["open mail and write {person} an email saying I'll be late", "launch Mail then draft a note to {person} about {title}"],
         lambda slots: [("open_app", "open", "Mail"), ("mail", "", None)]),
        (["open messages and text {person} that I'm here", "go to Messages then tell {person} I'm running late"],
         lambda slots: [("open_app", "open", "Messages"), ("messages", "", None)]),
        (["open spotify and play {track}", "launch spotify then put on {track} and turn it up"],
         lambda slots: [("open_app", "open", "Spotify"), ("music", "play", None), ("volume", "up", None)][:2 + (1 if "turn it up" in slots.get("_template", "") else 0)]),
        (["open {app} and snap it to the {position}", "launch {app} then put it on the {position} half"],
         lambda slots: [("open_app", "open", slots["app"]), ("window_snap", slots["position"], None)]),
        (["click the search field and type {text}", "click search, type {text}, then hit enter"],
         lambda slots: [("click", "Search", None), ("type", "type " + slots["text"], None)] + ([("key", "press return", None)] if "enter" in slots.get("_template", "") else [])),
        (["open my {folder} and open {file}", "go to {folder} in finder then double click {file}"],
         lambda slots: [("finder", slots["folder"].lower(), None), ("double_click", slots["file"], None)]),
        (["open a new tab and go to {site}", "press cmd t then type {site} and hit return"],
         lambda slots: [("key", "cmd t", None), ("type", "type " + slots["site"], None), ("key", "press return", None)]),
        (["scroll down and click {label}", "scroll down a bit then hit {label}"],
         lambda slots: [("scroll", "down", None), ("click", slots["label"], None)]),
        (["check my calendar and then add {title} tomorrow at 3", "what's on today, then schedule {title} at 4"],
         lambda slots: [("calendar", "today", None), ("calendar_create", "", None)]),
        (["open {site} and click {label}", "go to {site} then click {label}"],
         lambda slots: [("open_url", slots["site"], slots["site"]), ("click", slots["label"], None)]),
        (["copy what's on my clipboard into a note", "read my clipboard then make a note of it"],
         lambda slots: [("clipboard_read", "", None), ("notes", "", None)]),
        (["turn the volume down and dim the screen", "lower the brightness then mute"],
         lambda slots: [("volume", "down", None), ("brightness", "down", None)]),
        (["remind me to {title} and add it to Things", "set a reminder to {title}, then a 10 minute timer"],
         lambda slots: [("reminder", "remind me to " + slots["title"], None), ("things" if "Things" in slots.get("_template", "") else "start_timer", "", None)]),
    ]

    def build_plan_from_template(self):
        templates, build_plan = self.random_generator.choice(self.TEMPLATE_PLANS)
        candidate = self.template_candidate("plan:" + templates[0], templates)
        if candidate is None:
            return None
        slot_values = dict(candidate["slot_values"])
        template_text = next((template for template in templates if fill_like(template, candidate["text"])), templates[0])
        slot_values["_template"] = template_text
        return candidate, build_plan(slot_values)

    def build_plan_from_real(self):
        candidate = self.pools["multi_step"].draw()
        plan_steps = []
        for clause_text, (route_kind, route_detail) in candidate["route_detail"]:
            if route_kind == "destructive":
                plan_steps.append(("ASK_USER", clause_text, None))
            elif route_kind == "compose":
                plan_steps.append((route_detail, clause_text, None))
            elif route_kind == "click":
                reference_kind, reference_value, reference_role = route_detail
                plan_steps.append(("click", reference_value if reference_kind == "label" else ("ordinal", reference_value, reference_role), None))
            elif route_kind in ("tool_with_app", "tool_with_url"):
                plan_steps.append((route_detail[0], clause_text, route_detail[1]))
            else:
                plan_steps.append((route_detail, clause_text, None))
        return candidate, plan_steps

    def screen_after_steps(self, plan_steps, completed_count, next_step):
        """Screen reflects the most recently opened app, and contains the next click target if there is one."""
        current_app = None
        for tool_name, clause_text, route_argument in plan_steps[:completed_count]:
            if tool_name == "open_app":
                current_app = route_argument
            elif tool_name in ("open_url",):
                current_app = "Safari"
            elif tool_name == "finder":
                current_app = "Finder"
            elif tool_name in ("mail", "messages", "notes"):
                current_app = {"mail": "Mail", "messages": "Messages", "notes": "Notes"}[tool_name]
        click_target_specs = []
        ordinal_reference = None
        for tool_name, clause_text, _ in plan_steps:
            if tool_name in ("click", "double_click"):
                if isinstance(clause_text, tuple):
                    ordinal_reference = clause_text
                else:
                    role = "row" if tool_name == "double_click" else ("text_field" if clause_text == "Search" else "button")
                    click_target_specs.append((role, clause_text, ""))
        if ordinal_reference is not None:
            screen_elements, _ = self.screen_with_ordinal_target(ordinal_reference[1], ordinal_reference[2])
            return screen_elements
        return random_screen(self.random_generator, current_app, extra_specs=click_target_specs, allow_empty=not click_target_specs)

    def execute_plan_prefix(self, plan_steps, completed_count, screen_elements, fail_last=False, request_text=""):
        completed_steps = []
        for step_index, (tool_name, clause_text, route_argument) in enumerate(plan_steps[:completed_count]):
            target_element = None
            if tool_name in ("click", "double_click"):
                if isinstance(clause_text, tuple):
                    ordinal_index = clause_text[1]
                    matching_elements = [element for element in screen_elements if element["role"] == clause_text[2]]
                    target_element = matching_elements[ordinal_index] if matching_elements else None
                else:
                    target_element = next((element for element in screen_elements if element["label"] == clause_text), None)
            # Template plans carry short placeholder clause text; fall back to the whole request for content slots.
            argument_context_text = clause_text if isinstance(clause_text, str) and len(clause_text.split()) > 2 else request_text
            if tool_name in ("open_app", "open_url", "volume", "brightness", "scroll", "window_snap", "music", "key", "finder", "calendar") and isinstance(clause_text, str):
                argument_context_text = clause_text
            tool_arguments = synthesize_arguments(tool_name, argument_context_text, screen_elements,
                                                  self.random_generator, target_element=target_element, route_argument=route_argument)
            # "... then also add IT to my calendar": the pronoun refers to the previous step's title.
            refers_to_previous_step = isinstance(clause_text, str) and re.search(r"\b(it|that)\b", clause_text)
            title_is_only_a_lead_time = re.match(r"^\d+ (?:minute|hour|day)s?", str(tool_arguments.get("title", "")))
            if ((refers_to_previous_step or title_is_only_a_lead_time) and completed_steps
                    and "title" in tool_arguments and "title" in completed_steps[-1]["args"]):
                tool_arguments["title"] = completed_steps[-1]["args"]["title"]
            is_failed_step = fail_last and step_index == completed_count - 1
            completed_steps.append(completed_step(tool_name, tool_arguments, screen_elements, self.random_generator, failed=is_failed_step))
        return completed_steps

    def draw_plan(self):
        use_real = "multi_step" in self.pools and self.random_generator.random() < self.real_probability_for_pool("multi_step", 2000)
        plan = self.build_plan_from_real() if use_real else self.build_plan_from_template()
        if plan is None or len(plan[1]) < 2:
            return None
        return plan

    def generate_multi_step_intermediate(self):
        plan = self.draw_plan()
        if plan is None:
            return None
        candidate, plan_steps = plan
        executable_prefix_length = next((index for index, step in enumerate(plan_steps) if step[0] == "ASK_USER"), len(plan_steps))
        if executable_prefix_length < 1:
            return None
        completed_count = self.random_generator.randint(1, min(executable_prefix_length, len(plan_steps) - 1, 3))
        next_tool = plan_steps[completed_count][0]
        screen_elements = self.screen_after_steps(plan_steps, completed_count, plan_steps[completed_count])
        completed_steps = self.execute_plan_prefix(plan_steps, completed_count, screen_elements, request_text=candidate['text'])
        return self.make_row("multi_step_intermediate", candidate, screen_elements, completed_steps, next_tool)

    # ---------------------------------------------------- already done / failures

    def generate_already_done(self, rows_per_tool):
        """Completed steps fully satisfy the request. Sub-kinds keep DONE from being learnt as one surface cue."""
        sub_kind = self.random_generator.choices(
            ["single_tool", "click", "compose", "multi_step", "retry_succeeded"], weights=[45, 15, 10, 22, 8])[0]
        if sub_kind in ("single_tool", "retry_succeeded"):
            tool_name = self.random_generator.choice(self.tool_names)
            state = self.single_tool_state(tool_name, rows_per_tool)
            if state is None:
                return None
            candidate, screen_elements, target_element, chosen_tool = state
            tool_arguments = synthesize_arguments(chosen_tool, strip_conversational_fillers(candidate["text"]), screen_elements,
                                                  self.random_generator, target_element=target_element, route_argument=candidate.get("route_argument"))
            completed_steps = []
            if sub_kind == "retry_succeeded":
                completed_steps.append(completed_step(chosen_tool, tool_arguments, screen_elements, self.random_generator, failed=True))
            completed_steps.append(completed_step(chosen_tool, tool_arguments, screen_elements, self.random_generator))
            # Asking for a calendar read or clipboard read is "done" once the data came back; the
            # spoken answer is the planner's job, so DONE vs RESPOND is a teacher call → keep the guess.
            return self.make_row("already_done", candidate, screen_elements, completed_steps, "DONE")
        if sub_kind == "click":
            state = self.click_state(prefer_double_click=self.random_generator.random() < 0.15)
            if state is None:
                return None
            candidate, screen_elements, target_element, tool_name = state
            tool_arguments = synthesize_arguments(tool_name, "", screen_elements, self.random_generator, target_element=target_element)
            completed_steps = [completed_step(tool_name, tool_arguments, screen_elements, self.random_generator)]
            return self.make_row("already_done", candidate, screen_elements, completed_steps, "DONE")
        if sub_kind == "compose":
            candidate, compose_tool = self.compose_candidate()
            if candidate is None:
                return None
            screen_elements = random_screen(self.random_generator, {"mail": "Mail", "messages": "Messages", "notes": "Notes"}[compose_tool])
            tool_arguments = synthesize_arguments(compose_tool, strip_conversational_fillers(candidate["text"]), screen_elements, self.random_generator)
            completed_steps = [completed_step(compose_tool, tool_arguments, screen_elements, self.random_generator)]
            # Mail/Messages only draft. "send ..." requests may still need a confirm-to-send step: teacher decides.
            intended_label = None if re.search(r"\bsend\b", candidate["text"].lower()) and compose_tool != "notes" else "DONE"
            return self.make_row("already_done", candidate, screen_elements, completed_steps, intended_label)
        plan = self.draw_plan()
        if plan is None:
            return None
        candidate, plan_steps = plan
        if any(step[0] == "ASK_USER" for step in plan_steps) or len(plan_steps) > 4:
            return None
        screen_elements = self.screen_after_steps(plan_steps, len(plan_steps), None)
        completed_steps = self.execute_plan_prefix(plan_steps, len(plan_steps), screen_elements, request_text=candidate['text'])
        return self.make_row("already_done", candidate, screen_elements, completed_steps, "DONE")

    def generate_after_failure(self, rows_per_tool):
        """Last completed step returned an error. Retry / ask / explain are all defensible, so no guess."""
        if self.random_generator.random() < 0.5:
            plan = self.draw_plan()
            if plan is None:
                return None
            candidate, plan_steps = plan
            executable_prefix_length = next((index for index, step in enumerate(plan_steps) if step[0] == "ASK_USER"), len(plan_steps))
            if executable_prefix_length < 1:
                return None
            completed_count = self.random_generator.randint(1, executable_prefix_length)
            screen_elements = self.screen_after_steps(plan_steps, completed_count - 1, plan_steps[completed_count - 1])
            completed_steps = self.execute_plan_prefix(plan_steps, completed_count, screen_elements, fail_last=True, request_text=candidate['text'])
            return self.make_row("after_failure", candidate, screen_elements, completed_steps, None)
        tool_name = self.random_generator.choice(self.tool_names)
        state = self.single_tool_state(tool_name, rows_per_tool)
        if state is None:
            return None
        candidate, screen_elements, target_element, chosen_tool = state
        tool_arguments = synthesize_arguments(chosen_tool, strip_conversational_fillers(candidate["text"]), screen_elements,
                                              self.random_generator, target_element=target_element, route_argument=candidate.get("route_argument"))
        completed_steps = [completed_step(chosen_tool, tool_arguments, screen_elements, self.random_generator, failed=True)]
        return self.make_row("after_failure", candidate, screen_elements, completed_steps, None)


def annotation_target_label(request_text):
    """"circle the save button" → "Save", so the screen contains what a real annotation request points at."""
    target_match = re.search(
        r"\b(?:circle|highlight|point (?:to|at|out)|underline|mark|show me where|draw (?:a \w+ |an arrow )?(?:around|to|at|on))\s+"
        r"(?:the\s+|my\s+)?(.+?)(?:\s+(?:button|icon|tab|link|field|menu|is|on (?:the )?screen))*$",
        strip_conversational_fillers(request_text))
    if not target_match:
        return None
    target_words = target_match.group(1).split()
    if not 1 <= len(target_words) <= 3 or set(target_words) & {"it", "this", "that", "where", "here"}:
        return None
    return " ".join(word.capitalize() for word in target_words)


def fill_like(template_text, rendered_text):
    """True when rendered_text could have come from template_text (slots match anything)."""
    template_pattern = "^" + re.sub(r"\\\{\w+\\\}", ".+?", re.escape(template_text)) + "$"
    return re.match(template_pattern, rendered_text) is not None


_TOOL_CATALOG_CACHE = {}


def load_tool_catalog_example_utterance(tool_name):
    if not _TOOL_CATALOG_CACHE:
        _TOOL_CATALOG_CACHE.update(load_tool_catalog())
    return _TOOL_CATALOG_CACHE[tool_name]["example_utterance"]


# ================================================================ orchestration

def generate_all_rows(total_row_count, seed, phrasing_pools, tool_names, fixture_exclusion_index):
    generator = StepStateGenerator(phrasing_pools, tool_names, seed, fixture_exclusion_index)
    rows_per_tool = max(1, int(total_row_count * SCENARIO_SHARE_OF_TOTAL["single_tool_first_step"] / len(tool_names)))
    generated_rows = []
    seen_row_fingerprints = set()
    for scenario_name, scenario_share in SCENARIO_SHARE_OF_TOTAL.items():
        scenario_quota = int(round(total_row_count * scenario_share))
        scenario_rows = 0
        attempts = 0
        while scenario_rows < scenario_quota and attempts < scenario_quota * 20:
            attempts += 1
            if scenario_name == "single_tool_first_step":
                row = generator.generate_single_tool_first_step(tool_names[scenario_rows % len(tool_names)], rows_per_tool)
            elif scenario_name in ("already_done", "after_failure"):
                row = getattr(generator, f"generate_{scenario_name}")(rows_per_tool)
            else:
                row = getattr(generator, f"generate_{scenario_name}")()
            if row is None:
                continue
            row_fingerprint = json.dumps([row["request"], row["screen_elements"], row["completed_steps"]], sort_keys=True)
            if row_fingerprint in seen_row_fingerprints:
                continue
            seen_row_fingerprints.add(row_fingerprint)
            generated_rows.append(row)
            scenario_rows += 1
    return generated_rows


def enforce_split_isolation(generated_rows, fixture_exclusion_index):
    """Drops train rows whose request near-duplicates any sealed request, and any row that slipped
    past the fixture exclusion (template slot filling can produce a fixture-like string)."""
    sealed_index = NearDuplicateIndex()
    for core_key in sorted({row["core_key"] for row in generated_rows if row["split"] == "sealed"}):
        sealed_index.add(core_key)
    kept_rows, dropped_for_leak, dropped_for_fixture = [], 0, 0
    leak_check_cache = {}
    for row in generated_rows:
        if fixture_exclusion_index.contains_near_duplicate(row["core_key"]):
            dropped_for_fixture += 1
            continue
        if row["split"] == "train":
            if row["core_key"] not in leak_check_cache:
                leak_check_cache[row["core_key"]] = sealed_index.contains_near_duplicate(row["core_key"])
            if leak_check_cache[row["core_key"]]:
                dropped_for_leak += 1
                continue
        kept_rows.append(row)
    return kept_rows, dropped_for_leak, dropped_for_fixture


def coverage_report(final_rows, tool_names, source_notes, phrasing_pools, isolation_stats, arguments):
    def count_by(key_function, rows):
        return dict(sorted(collections.Counter(key_function(row) for row in rows).items(), key=lambda item: (-item[1], str(item[0]))))
    real_phrasing_pool_sizes = {pool_name: len(candidates) for pool_name, candidates in sorted(phrasing_pools.items())}
    first_step_label_source_mix = {}
    for tool_name in tool_names + list(CONTROL_LABEL_DESCRIPTIONS):
        label_rows = [row for row in final_rows if row["intended_label"] == tool_name]
        first_step_label_source_mix[tool_name] = {
            "rows": len(label_rows),
            "template_share": round(sum(1 for row in label_rows if row["source"] == "template") / len(label_rows), 2) if label_rows else None,
            "unique_requests": len({row["core_key"] for row in label_rows}),
        }
    return {
        "arguments": arguments,
        "total_rows": len(final_rows),
        "by_split": count_by(lambda row: row["split"], final_rows),
        "by_scenario": count_by(lambda row: row["scenario"], final_rows),
        "by_scenario_and_split": count_by(lambda row: f"{row['scenario']}|{row['split']}", final_rows),
        "by_intended_label": count_by(lambda row: str(row["intended_label"]), final_rows),
        "by_source": count_by(lambda row: row["source"], final_rows),
        "by_completed_step_count": count_by(lambda row: len(row["completed_steps"]), final_rows),
        "label_source_mix": first_step_label_source_mix,
        "unique_requests_by_split": {split_name: len({row["core_key"] for row in final_rows if row["split"] == split_name})
                                     for split_name in ("train", "sealed")},
        "real_phrasing_pool_sizes": real_phrasing_pool_sizes,
        "source_notes": source_notes,
        "split_isolation": isolation_stats,
    }


# ================================================================ extra scenarios: goal-phrased clicks (--extra-scenarios-only)
#
# The first student routed abstract click requests ("i want to leave a tip" with one fitting button)
# to ASK_USER because every click it trained on named its target literally. This mode writes NEW
# files (train-extra / sealed-extra / coverage-extra) from a hand-written goal↔element catalog and
# never touches train.jsonl / sealed.jsonl, whose teacher labels are already paid for.

EXTRA_SCENARIO_SHARE_OF_TOTAL = {"abstract_click": 0.50, "disfluent_click": 0.26, "abstract_ambiguous": 0.24}
# Stricter than the 0.8 used for the base data: short goal phrasings sit close to the click fixtures.
EXTRA_FIXTURE_REQUEST_JACCARD_THRESHOLD = 0.6
FIXTURE_LABEL_SET_OVERLAP_LIMIT = 2


def load_goal_click_catalog():
    catalog_spec = importlib.util.spec_from_file_location(
        "router_goal_click_catalog", REPO_ROOT / "scripts" / "router-goal-click-catalog.py")
    catalog_module = importlib.util.module_from_spec(catalog_spec)
    catalog_spec.loader.exec_module(catalog_module)
    return catalog_module


def normalized_element_label(label):
    label = label.lower().strip()
    return re.sub(r"\s+(?:button|icon|field|link|tab)$", "", label)


def load_fixture_element_label_sets():
    """One label set per harness fixture that has screen elements. A generated screen may not share
    FIXTURE_LABEL_SET_OVERLAP_LIMIT or more labels with any of them (same category is fine, same instance is not)."""
    fixture_label_sets = []
    for fixture_path in sorted(glob.glob(str(REPO_ROOT / "evals" / "fm-fixtures*" / "*.txt"))):
        labels = set()
        for raw_line in Path(fixture_path).read_text().splitlines():
            element_match = re.match(r"ELEMENT:\s*\[\d+\]\s*[^|]*\|-?\d+,-?\d+\|([^|]*)", raw_line)
            if element_match and element_match.group(1).strip():
                labels.add(normalized_element_label(element_match.group(1)))
        if len(labels) >= 2:
            fixture_label_sets.append(labels)
    return fixture_label_sets


def screen_reuses_fixture_instance(screen_labels, fixture_label_sets):
    normalized_screen_labels = {normalized_element_label(label) for label in screen_labels}
    return any(len(normalized_screen_labels & fixture_labels) >= FIXTURE_LABEL_SET_OVERLAP_LIMIT
               for fixture_labels in fixture_label_sets)


def display_attribute_value(attribute_name, value):
    """Human-readable units for attribute-pick rows (the catalog stores plain integers)."""
    if attribute_name in ("price", "rent"):
        return f"${value:,}"
    if attribute_name == "duration_minutes":
        return f"{value // 60}h {value % 60:02d}m"
    if attribute_name == "departure_hour":
        return f"{(value - 1) % 12 + 1}:{(value * 7) % 60:02d} {'AM' if value < 12 else 'PM'}"
    if attribute_name == "stops":
        return "nonstop" if value == 0 else f"{value} stop{'s' if value > 1 else ''}"
    if attribute_name == "weight_pounds_tenths":
        return f"{value / 10:.1f} lb"
    if attribute_name in ("battery_hours",):
        return f"{value} hr"
    if attribute_name == "square_feet":
        return f"{value} sq ft"
    if attribute_name in ("minutes_to_train", "minutes"):
        return f"{value} min"
    if attribute_name in ("rating_tenths", "review_tenths"):
        return f"{value / 10:.1f}★"
    if attribute_name == "calories":
        return f"{value} cal"
    if attribute_name == "distance_tenths_miles":
        return f"{value / 10:.1f} mi"
    if attribute_name == "closing_hour":
        return "midnight" if value >= 24 else f"{value - 12} PM"
    if attribute_name == "megabytes":
        return f"{value / 1000:.1f} GB" if value >= 1000 else f"{value} MB"
    if attribute_name == "days_since_modified":
        return "today" if value == 0 else f"{value} days ago"
    if attribute_name == "hours_waiting":
        return f"{value} h"
    if attribute_name == "review_count":
        return f"{value:,}"
    return str(value)


DISFLUENT_LITERAL_CLICK_TEMPLATES = [
    "uh, can you hit the, um, {target} thing",
    "click {wrong} — no wait, sorry, {target}",
    "press {wrong}, i mean {target}",
    "the... the {target} one? yeah, that",
    "could you maybe like select {target}? i think it's called {target}",
    "go to— actually just click {target}",
    "um, the, what's it called, {target}, that button",
    "not {wrong}, the other one, {target}",
    "hmm, {target}? yeah, tap {target}",
    "okay so like, i need you to, uh, hit {target} real quick",
    "{target}. click {target}. sorry, my brain's slow today",
    "can you, uh— the {target} button, can you press it",
    "wait, scratch that, not {wrong}, hit {target}",
    "so there's a, uh, {target} thing on there, click it",
    "click on, um, i wanna say {target}?",
    "i think it's {target}, yeah, try {target}",
    "{wrong}— no no no, {target}, click {target}",
    "press the uh, the uh, {target}",
    "could you like, kinda, hit {target} for me? thanks",
    "ok um. {target}. that one.",
    "tap... hold on... {target}, yeah",
    "er, open up the {target}— i mean click it, the {target} button",
]
DISFLUENT_PREFIXES = ["uh ", "um, ", "so, like, ", "okay so ", "hmm, ", "uh, can you, ", "wait, um, ", "so yeah, "]
DISFLUENT_SUFFIXES = ["", "", " — you know?", ", i think", ", if that makes sense", " or whatever", "... yeah", ", um, please"]
DISFLUENT_INFIXES = ["uh", "like", "um", "kind of", "you know"]


def disfluent_version_of_goal(goal_phrasing, random_generator):
    """Fillers and hedges around a goal phrasing; the goal itself, and so the one fitting element, is unchanged."""
    words = goal_phrasing.split()
    for _ in range(random_generator.randint(1, 2)):
        insert_at = random_generator.randint(1, max(1, len(words) - 1))
        words.insert(insert_at, random_generator.choice(DISFLUENT_INFIXES) + ",")
    return random_generator.choice(DISFLUENT_PREFIXES) + " ".join(words) + random_generator.choice(DISFLUENT_SUFFIXES)


class ExtraClickStateGenerator:
    def __init__(self, seed, fixture_request_index, fixture_label_sets):
        # A separate stream so the base generator's draws (and its byte-identical output) are untouched.
        self.random_generator = random.Random(seed * 1000 + 7)
        self.seed = seed
        self.catalog = load_goal_click_catalog()
        self.context_by_app = {context["app"]: context for context in self.catalog.APP_SCREEN_CONTEXTS}
        self.fixture_request_index = fixture_request_index
        self.fixture_label_sets = fixture_label_sets
        self.guard_counts = collections.Counter()
        self.unit_queues = {}

    # ---------------------------------------------------- shared helpers

    def request_is_fixture_like(self, request_text):
        return self.fixture_request_index.contains_near_duplicate(
            core_phrasing_key(request_text), threshold=EXTRA_FIXTURE_REQUEST_JACCARD_THRESHOLD)

    def next_unit(self, queue_name, build_units):
        """Cycles through every unit (goal × phrasing) before repeating any, reshuffling each pass."""
        if not self.unit_queues.get(queue_name):
            units = build_units()
            self.random_generator.shuffle(units)
            self.unit_queues[queue_name] = units
        return self.unit_queues[queue_name].pop()

    def laid_out_screen(self, element_specs):
        """3–8 elements, no dock; rejects screens that reuse a fixture's label set."""
        if screen_reuses_fixture_instance([label for _, label, _ in element_specs], self.fixture_label_sets):
            self.guard_counts["screens_rejected_fixture_label_overlap"] += 1
            return None
        return layout_screen_elements(element_specs, self.random_generator, include_dock=False)

    def distractor_specs(self, context, excluded_labels, distractor_count):
        candidates = [spec for spec in context["elements"] if spec[1] not in excluded_labels]
        return self.random_generator.sample(candidates, min(distractor_count, len(candidates)))

    def make_extra_row(self, scenario, source, request_text, screen_elements, intended_label, split_group, detail):
        return {"scenario": scenario, "source": source, "request": request_text, "screen_elements": screen_elements,
                "completed_steps": [], "intended_label": intended_label,
                "split": "sealed" if stable_unit_interval("split:" + split_group, self.seed) < SEALED_SPLIT_FRACTION else "train",
                "core_key": core_phrasing_key(request_text), "detail": detail}

    # ---------------------------------------------------- abstract_click

    def catalog_goal_units(self):
        return [(context["app"], goal_index, phrasing)
                for context in self.catalog.APP_SCREEN_CONTEXTS
                for goal_index, (_, _, phrasings) in enumerate(context["goals"])
                for phrasing in phrasings]

    def abstract_click_from_catalog(self, make_disfluent=False):
        app_name, goal_index, phrasing = self.next_unit("catalog_goals", self.catalog_goal_units)
        context = self.context_by_app[app_name]
        target_label, alternate_labels, _ = context["goals"][goal_index]
        request_text = disfluent_version_of_goal(phrasing, self.random_generator) if make_disfluent else phrasing
        if self.request_is_fixture_like(request_text):
            self.guard_counts["requests_rejected_fixture_near_duplicate"] += 1
            return None
        target_spec = next(spec for spec in context["elements"] if spec[1] == target_label)
        # Alternates also fit these phrasings, so they never appear here. Near-misses that fit only a
        # different phrasing (Theater Mode for "the whole display") stay in as hard negatives.
        distractors = self.distractor_specs(context, {target_label} | set(alternate_labels), self.random_generator.randint(2, 7))
        screen_elements = self.laid_out_screen([target_spec] + distractors)
        if screen_elements is None:
            return None
        scenario = "disfluent_click" if make_disfluent else "abstract_click"
        source = "goal-catalog-disfluent" if make_disfluent else "goal-catalog"
        return self.make_extra_row(scenario, source, request_text, screen_elements, "click",
                                   f"goal:{app_name}:{goal_index}", {"app": app_name, "target": target_label})

    def dock_goal_units(self):
        return [(goal_index, phrasing) for goal_index, (_, _, phrasings) in enumerate(self.catalog.APP_PURPOSE_GOALS) for phrasing in phrasings]

    def abstract_click_from_dock(self, ambiguous=False):
        if ambiguous:
            goal_index, phrasing = self.next_unit("dock_goals_ambiguous", lambda: [
                unit for unit in self.dock_goal_units() if self.catalog.APP_PURPOSE_GOALS[unit[0]][1]])
        else:
            goal_index, phrasing = self.next_unit("dock_goals", self.dock_goal_units)
        target_app, alternate_apps, _ = self.catalog.APP_PURPOSE_GOALS[goal_index]
        if self.request_is_fixture_like(phrasing):
            self.guard_counts["requests_rejected_fixture_near_duplicate"] += 1
            return None
        excluded_apps = {target_app, *alternate_apps}
        distractor_apps = self.random_generator.sample([app for app in self.catalog.DOCK_APP_POOL if app not in excluded_apps],
                                                       self.random_generator.randint(2, 6))
        shown_apps = [target_app] + ([self.random_generator.choice(alternate_apps)] if ambiguous else []) + distractor_apps
        self.random_generator.shuffle(shown_apps)
        if screen_reuses_fixture_instance(shown_apps, self.fixture_label_sets):
            self.guard_counts["screens_rejected_fixture_label_overlap"] += 1
            return None
        screen_width, screen_height = self.random_generator.choice(SCREEN_SIZES)
        dock_y = screen_height - self.random_generator.randint(20, 40)
        dock_x_start = self.random_generator.randint(screen_width // 4, screen_width // 3)
        screen_elements = [{"id": icon_index, "role": "dock_icon", "x": dock_x_start + icon_index * 64, "y": dock_y,
                            "label": app_name, "text": ""} for icon_index, app_name in enumerate(shown_apps)]
        return self.make_extra_row("abstract_ambiguous" if ambiguous else "abstract_click", "goal-catalog-dock", phrasing,
                                   screen_elements, "ASK_USER" if ambiguous else "click",
                                   f"dock:{goal_index}", {"app": "Dock", "target": target_app})

    def attribute_pick(self, ambiguous=False):
        """A list of same-kind rows; the request asks for an extreme of one attribute. Ambiguous rows tie
        two items at that extreme, so either fits."""
        domain = self.random_generator.choice(self.catalog.ATTRIBUTE_PICK_DOMAINS)
        (attribute_name, direction), phrasings = self.random_generator.choice(sorted(domain["asks"].items()))
        phrasing = self.random_generator.choice(phrasings)
        if self.request_is_fixture_like(phrasing):
            self.guard_counts["requests_rejected_fixture_near_duplicate"] += 1
            return None
        item_count = self.random_generator.randint(3, min(6, len(domain["labels"])))
        item_labels = self.random_generator.sample(domain["labels"], item_count)
        for _ in range(50):
            item_values = [{name: self.random_generator.randint(low, high) for name, (low, high) in domain["attributes"].items()}
                           for _ in item_labels]
            attribute_values = [values[attribute_name] for values in item_values]
            extreme_value = min(attribute_values) if direction == "min" else max(attribute_values)
            extreme_count = attribute_values.count(extreme_value)
            if ambiguous:
                if extreme_count == 1:
                    # Force a tie: copy the extreme onto one other item.
                    other_index = self.random_generator.choice([index for index, value in enumerate(attribute_values) if value != extreme_value])
                    item_values[other_index][attribute_name] = extreme_value
                break
            if extreme_count == 1:
                break
        else:
            return None
        element_specs = []
        for item_label, values in zip(item_labels, item_values):
            item_text = domain["text"].format(**{name: display_attribute_value(name, value) for name, value in values.items()})
            element_specs.append((domain["role"], item_label, item_text))
        chrome_specs = [("button", label, "") for label in self.random_generator.sample(["Filters", "Sort", "Map View", "Back"], self.random_generator.randint(0, 2))]
        screen_elements = self.laid_out_screen(element_specs + chrome_specs)
        if screen_elements is None:
            return None
        return self.make_extra_row("abstract_ambiguous" if ambiguous else "abstract_click", "goal-catalog-attribute", phrasing,
                                   screen_elements, "ASK_USER" if ambiguous else "click",
                                   f"attribute:{domain['domain']}:{attribute_name}:{direction}",
                                   {"app": f"list: {domain['domain']}", "target": f"{direction} {attribute_name}"})

    # ---------------------------------------------------- disfluent_click

    def disfluent_literal_click(self):
        template_index = self.random_generator.randrange(len(DISFLUENT_LITERAL_CLICK_TEMPLATES))
        template_text = DISFLUENT_LITERAL_CLICK_TEMPLATES[template_index]
        context = self.random_generator.choice(self.catalog.APP_SCREEN_CONTEXTS)
        goal_target_labels = sorted({target for target, _, _ in context["goals"]})
        target_label = self.random_generator.choice(goal_target_labels)
        target_spec = next(spec for spec in context["elements"] if spec[1] == target_label)
        other_specs = [spec for spec in context["elements"] if spec[1] != target_label]
        wrong_spec = self.random_generator.choice(other_specs)
        request_text = template_text.format(target=target_label.lower(), wrong=wrong_spec[1].lower())
        if self.request_is_fixture_like(request_text):
            self.guard_counts["requests_rejected_fixture_near_duplicate"] += 1
            return None
        distractors = self.distractor_specs(context, {target_label, wrong_spec[1]}, self.random_generator.randint(2, 6))
        # The corrected-away element is on screen when the template names it, so the self-correction matters.
        screen_specs = [target_spec] + ([wrong_spec] if "{wrong}" in template_text else []) + distractors
        screen_elements = self.laid_out_screen(screen_specs[:8])
        if screen_elements is None:
            return None
        return self.make_extra_row("disfluent_click", "disfluent-template", request_text, screen_elements, "click",
                                   f"disfluent-template:{template_index}", {"app": context["app"], "target": target_label})

    # ---------------------------------------------------- abstract_ambiguous (catalog)

    def ambiguous_goal_units(self):
        units = [("ambiguous_goal", entry_index, phrasing)
                 for entry_index, (_, _, phrasings) in enumerate(self.catalog.AMBIGUOUS_GOALS) for phrasing in phrasings]
        units += [("alternate_goal", (context["app"], goal_index), phrasing)
                  for context in self.catalog.APP_SCREEN_CONTEXTS
                  for goal_index, (_, alternate_labels, phrasings) in enumerate(context["goals"]) if alternate_labels
                  for phrasing in phrasings]
        return units

    def abstract_ambiguous_from_catalog(self):
        unit_kind, unit_key, phrasing = self.next_unit("ambiguous_goals", self.ambiguous_goal_units)
        if unit_kind == "ambiguous_goal":
            app_name, fitting_labels, _ = self.catalog.AMBIGUOUS_GOALS[unit_key]
            shown_fitting_labels = self.random_generator.sample(fitting_labels, self.random_generator.randint(2, len(fitting_labels)))
            split_group = f"ambiguous:{unit_key}"
        else:
            app_name, goal_index = unit_key
            target_label, alternate_labels, _ = self.context_by_app[app_name]["goals"][goal_index]
            fitting_labels = [target_label, *alternate_labels]
            shown_fitting_labels = [target_label, self.random_generator.choice(alternate_labels)]
            # Same group as the abstract_click rows of this goal: one goal, one split.
            split_group = f"goal:{app_name}:{goal_index}"
        if self.request_is_fixture_like(phrasing):
            self.guard_counts["requests_rejected_fixture_near_duplicate"] += 1
            return None
        context = self.context_by_app[app_name]
        fitting_specs = [spec for spec in context["elements"] if spec[1] in shown_fitting_labels]
        distractors = self.distractor_specs(context, set(fitting_labels), self.random_generator.randint(1, 8 - len(fitting_specs)))
        element_specs = fitting_specs + distractors
        self.random_generator.shuffle(element_specs)
        screen_elements = self.laid_out_screen(element_specs)
        if screen_elements is None:
            return None
        return self.make_extra_row("abstract_ambiguous", "goal-catalog", phrasing, screen_elements, "ASK_USER", split_group,
                                   {"app": app_name, "target": " | ".join(shown_fitting_labels)})

    # ---------------------------------------------------- scenario dispatch

    def generate_row(self, scenario_name):
        draw = self.random_generator.random()
        if scenario_name == "abstract_click":
            if draw < 0.65:
                return self.abstract_click_from_catalog()
            if draw < 0.80:
                return self.abstract_click_from_dock()
            return self.attribute_pick()
        if scenario_name == "disfluent_click":
            return self.disfluent_literal_click() if draw < 0.55 else self.abstract_click_from_catalog(make_disfluent=True)
        if draw < 0.65:
            return self.abstract_ambiguous_from_catalog()
        if draw < 0.77:
            return self.abstract_click_from_dock(ambiguous=True)
        return self.attribute_pick(ambiguous=True)


def read_existing_request_core_keys(output_directory, split_name):
    split_path = Path(output_directory) / f"{split_name}.jsonl"
    if not split_path.exists():
        return set()
    return {core_phrasing_key(json.loads(line)["request"]) for line in split_path.read_text().splitlines() if line.strip()}


def generate_extra_scenario_files(extra_total_row_count, seed, output_directory):
    """Writes train-extra.jsonl, sealed-extra.jsonl and coverage-extra.json. Never writes the base files."""
    output_directory = Path(output_directory)
    fixture_request_index, fixture_user_line_count = load_fixture_request_exclusion_index()
    fixture_label_sets = load_fixture_element_label_sets()
    generator = ExtraClickStateGenerator(seed, fixture_request_index, fixture_label_sets)

    generated_rows = []
    seen_row_fingerprints = set()
    for scenario_name, scenario_share in EXTRA_SCENARIO_SHARE_OF_TOTAL.items():
        scenario_quota = int(round(extra_total_row_count * scenario_share))
        scenario_rows, attempts = 0, 0
        while scenario_rows < scenario_quota and attempts < scenario_quota * 30:
            attempts += 1
            row = generator.generate_row(scenario_name)
            if row is None:
                continue
            row_fingerprint = json.dumps([row["request"], row["screen_elements"]], sort_keys=True)
            if row_fingerprint in seen_row_fingerprints:
                continue
            seen_row_fingerprints.add(row_fingerprint)
            generated_rows.append(row)
            scenario_rows += 1

    # Cross-split isolation, including against the existing (already labelled) base files.
    existing_train_index, existing_sealed_index, extra_sealed_index = NearDuplicateIndex(), NearDuplicateIndex(), NearDuplicateIndex()
    for core_key in sorted(read_existing_request_core_keys(output_directory, "train")):
        existing_train_index.add(core_key)
    for core_key in sorted(read_existing_request_core_keys(output_directory, "sealed")):
        existing_sealed_index.add(core_key)
    for core_key in sorted({row["core_key"] for row in generated_rows if row["split"] == "sealed"}):
        extra_sealed_index.add(core_key)
    kept_rows = []
    for row in generated_rows:
        if row["split"] == "train" and (extra_sealed_index.contains_near_duplicate(row["core_key"])
                                        or existing_sealed_index.contains_near_duplicate(row["core_key"])):
            generator.guard_counts["train_rows_dropped_near_duplicate_of_a_sealed_request"] += 1
            continue
        if row["split"] == "sealed" and existing_train_index.contains_near_duplicate(row["core_key"]):
            generator.guard_counts["sealed_rows_dropped_near_duplicate_of_base_train_request"] += 1
            continue
        if fixture_request_index.contains_near_duplicate(row["core_key"], threshold=EXTRA_FIXTURE_REQUEST_JACCARD_THRESHOLD):
            generator.guard_counts["rows_dropped_fixture_near_duplicate_final_pass"] += 1
            continue
        kept_rows.append(row)

    rows_by_split = {"train": [], "sealed": []}
    for row in kept_rows:
        row_identifier = hashlib.sha1(json.dumps([row["request"], row["screen_elements"]], sort_keys=True).encode()).hexdigest()[:12]
        # "extra-" prefix: base ids start with the scenario name, so the two id spaces cannot collide.
        rows_by_split[row["split"]].append({
            "id": f"extra-{row['scenario']}-{row_identifier}", "source": row["source"], "scenario": row["scenario"],
            "request": row["request"], "screen_elements": row["screen_elements"], "completed_steps": row["completed_steps"],
            "intended_label": row["intended_label"], "split": row["split"],
        })
    for split_name, split_rows in rows_by_split.items():
        with open(output_directory / f"{split_name}-extra.jsonl", "w") as split_file:
            for split_row in split_rows:
                split_file.write(json.dumps(split_row) + "\n")

    def count_by(key_function):
        return dict(sorted(collections.Counter(key_function(row) for row in kept_rows).items(), key=lambda item: (-item[1], str(item[0]))))
    catalog = generator.catalog
    coverage = {
        "arguments": {"extra_total": extra_total_row_count, "seed": seed},
        "total_rows": len(kept_rows),
        "by_split": count_by(lambda row: row["split"]),
        "by_scenario": count_by(lambda row: row["scenario"]),
        "by_scenario_and_split": count_by(lambda row: f"{row['scenario']}|{row['split']}"),
        "by_intended_label": count_by(lambda row: row["intended_label"]),
        "by_source": count_by(lambda row: row["source"]),
        "by_app_context": count_by(lambda row: row["detail"]["app"]),
        "screen_element_count": count_by(lambda row: len(row["screen_elements"])),
        "unique_requests_by_split": {split_name: len({row["core_key"] for row in kept_rows if row["split"] == split_name})
                                     for split_name in ("train", "sealed")},
        "distinct_target_elements_used": len({(row["detail"]["app"], row["detail"]["target"]) for row in kept_rows}),
        "catalog": {
            "app_contexts": len(catalog.APP_SCREEN_CONTEXTS),
            "goal_entries": sum(len(context["goals"]) for context in catalog.APP_SCREEN_CONTEXTS),
            "goal_phrasings": sum(len(phrasings) for context in catalog.APP_SCREEN_CONTEXTS for _, _, phrasings in context["goals"]),
            "distinct_goal_to_element_pairs": len({(context["app"], target) for context in catalog.APP_SCREEN_CONTEXTS for target, _, _ in context["goals"]}),
            "app_purpose_goals": len(catalog.APP_PURPOSE_GOALS),
            "ambiguous_goals": len(catalog.AMBIGUOUS_GOALS),
            "attribute_domains": len(catalog.ATTRIBUTE_PICK_DOMAINS),
        },
        "leakage_guards": {
            **dict(sorted(generator.guard_counts.items())),
            "fixture_user_lines_checked": fixture_user_line_count,
            "fixture_label_sets_checked": len(fixture_label_sets),
            "fixture_request_jaccard_threshold": EXTRA_FIXTURE_REQUEST_JACCARD_THRESHOLD,
            "fixture_label_set_overlap_limit": FIXTURE_LABEL_SET_OVERLAP_LIMIT,
            "cross_split_jaccard_threshold": NEAR_DUPLICATE_JACCARD_THRESHOLD,
        },
    }
    (output_directory / "coverage-extra.json").write_text(json.dumps(coverage, indent=2) + "\n")
    return rows_by_split, coverage



def main():
    argument_parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    argument_parser.add_argument("--total", type=int, default=15000, help="approximate number of rows across both splits")
    argument_parser.add_argument("--seed", type=int, default=13)
    argument_parser.add_argument("--output-dir", default=str(REPO_ROOT / "evals" / "router-data"))
    argument_parser.add_argument("--show-samples", type=int, default=15, help="print N random rows rendered as router input")
    argument_parser.add_argument("--extra-scenarios-only", action="store_true",
                                 help="write ONLY train-extra/sealed-extra/coverage-extra (goal-phrased, disfluent and "
                                      "ambiguous click states); the base files are not touched")
    argument_parser.add_argument("--extra-total", type=int, default=2500, help="approximate row count for --extra-scenarios-only")
    parsed_arguments = argument_parser.parse_args()

    if parsed_arguments.extra_scenarios_only:
        rows_by_split, coverage = generate_extra_scenario_files(parsed_arguments.extra_total, parsed_arguments.seed, parsed_arguments.output_dir)
        print(f"wrote {len(rows_by_split['train'])} train-extra + {len(rows_by_split['sealed'])} sealed-extra rows to {parsed_arguments.output_dir}")
        print(json.dumps({key: coverage[key] for key in ("by_scenario_and_split", "leakage_guards")}, indent=2))
        sample_generator = random.Random(parsed_arguments.seed + 1)
        all_extra_rows = rows_by_split["train"] + rows_by_split["sealed"]
        for sample_row in sample_generator.sample(all_extra_rows, min(parsed_arguments.show_samples, len(all_extra_rows))):
            print(f"\n--- {sample_row['id']}  split={sample_row['split']}  source={sample_row['source']}  intended={sample_row['intended_label']}")
            print(router_input_text({"user_request": sample_row["request"], "screen_elements": sample_row["screen_elements"]},
                                    sample_row["completed_steps"]))
        return

    tool_catalog = load_tool_catalog()
    tool_names = list(tool_catalog)
    label_names = list(router_label_descriptions(tool_catalog))
    assert len(label_names) == len(tool_names) + len(CONTROL_LABEL_DESCRIPTIONS), "label set drifted from registry"
    missing_templates = set(tool_names) - set(TEMPLATE_PHRASINGS_BY_TOOL)
    assert not missing_templates, f"registry tools without fallback templates: {sorted(missing_templates)}"

    fixture_exclusion_index, fixture_user_line_count = load_fixture_request_exclusion_index()
    phrasing_pools, source_notes = build_phrasing_pools(parsed_arguments.seed, fixture_exclusion_index)
    source_notes["fixture_user_lines_excluded_against"] = fixture_user_line_count

    generated_rows = generate_all_rows(parsed_arguments.total, parsed_arguments.seed, phrasing_pools, tool_names, fixture_exclusion_index)
    final_rows, dropped_for_leak, dropped_for_fixture = enforce_split_isolation(generated_rows, fixture_exclusion_index)
    if final_rows and len(final_rows) < parsed_arguments.total * 0.98:
        # Isolation drops some train rows; regenerate once with a proportionally larger quota so the
        # output lands near --total. Same seed, so the result is still deterministic.
        inflated_total = int(parsed_arguments.total * parsed_arguments.total / len(final_rows))
        generated_rows = generate_all_rows(inflated_total, parsed_arguments.seed, phrasing_pools, tool_names, fixture_exclusion_index)
        final_rows, dropped_for_leak, dropped_for_fixture = enforce_split_isolation(generated_rows, fixture_exclusion_index)

    output_directory = Path(parsed_arguments.output_dir)
    output_directory.mkdir(parents=True, exist_ok=True)
    rows_by_split = {"train": [], "sealed": []}
    for row_index, row in enumerate(final_rows):
        row_identifier = hashlib.sha1(json.dumps([row["request"], row["screen_elements"], row["completed_steps"]], sort_keys=True).encode()).hexdigest()[:12]
        rows_by_split[row["split"]].append({
            "id": f"{row['scenario']}-{row_identifier}", "source": row["source"], "scenario": row["scenario"],
            "request": row["request"], "screen_elements": row["screen_elements"], "completed_steps": row["completed_steps"],
            "intended_label": row["intended_label"], "split": row["split"],
        })
    for split_name, split_rows in rows_by_split.items():
        with open(output_directory / f"{split_name}.jsonl", "w") as split_file:
            for split_row in split_rows:
                split_file.write(json.dumps(split_row) + "\n")

    isolation_stats = {"train_rows_dropped_as_sealed_near_duplicates": dropped_for_leak,
                       "rows_dropped_as_fixture_near_duplicates": dropped_for_fixture,
                       "near_duplicate_jaccard_threshold": NEAR_DUPLICATE_JACCARD_THRESHOLD}
    coverage = coverage_report(final_rows, tool_names, source_notes, phrasing_pools, isolation_stats,
                               {"total": parsed_arguments.total, "seed": parsed_arguments.seed})
    (output_directory / "coverage.json").write_text(json.dumps(coverage, indent=2) + "\n")
    print(f"wrote {len(rows_by_split['train'])} train + {len(rows_by_split['sealed'])} sealed rows to {output_directory}")

    sample_generator = random.Random(parsed_arguments.seed + 1)
    all_output_rows = rows_by_split["train"] + rows_by_split["sealed"]
    for sample_row in sample_generator.sample(all_output_rows, min(parsed_arguments.show_samples, len(all_output_rows))):
        print(f"\n--- {sample_row['id']}  split={sample_row['split']}  source={sample_row['source']}  intended={sample_row['intended_label']}")
        print(router_input_text({"user_request": sample_row["request"], "screen_elements": sample_row["screen_elements"]},
                                sample_row["completed_steps"]))


if __name__ == "__main__":
    main()
