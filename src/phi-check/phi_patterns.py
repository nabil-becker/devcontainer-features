"""PHI patterns for phi-check (the phi-check Dev Container Feature).

Every pattern lives in this one module, so the command line tool, a commit
guard, an export check or a ledger or board write guard all decide the same
way. Python 3 standard library only.

    scan(text) -> [(line, rule), ...]   line is 1-based, sorted, no duplicates
    find(text) -> [rule, ...]           the distinct rules, in order of first hit

A rule is a fixed description such as "PHI tier 1: US Social Security
number". Nothing here ever returns, logs or raises with the matched text:
the value that tripped a rule must not reach any output.

Tier 1 patterns are refused on sight. Tier 2 patterns are refused only in
combination: an anchor (an identifier label with a value, or a date-of-birth
label with a date) with any other signal in a window of three lines centred
on the anchor.
"""
import re

VERSION = "1.0.0"

# ----------------------------------------------------------------- tier 1 --

_SSN_DASHED = re.compile(r"(?<![\w-])(\d{3})-(\d{2})-(\d{4})(?![\w-])")
_SSN_LABELLED = re.compile(
    r"(?i)(?<![A-Za-z0-9])(?:ssn|social\s+security\s*(?:number|no\.?|#))"
    r"[\s:=#]{0,3}(?<![0-9])\d{9}(?![0-9])"
)

# CMS Medicare Beneficiary Identifier: 11 characters, upper case.
#   pos 1 digit 1-9; 2,5,8,9 letters without S L O I B Z; 3,6 letter or digit;
#   4,7,10,11 digits. Optional dashes after the 4th and 7th character.
_L = "[AC-HJKMNP-RT-Y]"
_A = "[AC-HJKMNP-RT-Y0-9]"
_MBI = re.compile(
    r"(?<![A-Za-z0-9-])[1-9]" + _L + _A + r"[0-9]-?"
    + _L + _A + r"[0-9]-?" + _L + _L + r"[0-9][0-9](?![A-Za-z0-9-])"
)

_X12 = [
    ("PHI tier 1: X12 NM1 segment naming a person",
     re.compile(r"(?<![A-Za-z0-9*])NM1\*(?:IL|QC)\*1\*[^*~\s]")),
    ("PHI tier 1: X12 DMG segment with a birth date",
     re.compile(r"(?<![A-Za-z0-9*])DMG\*D8\*\d{8}")),
    ("PHI tier 1: X12 INS segment for a subscriber or dependent",
     re.compile(r"(?<![A-Za-z0-9*])INS\*[YN]\*\d{2}\*")),
    ("PHI tier 1: X12 HI segment with a diagnosis code",
     re.compile(r"(?<![A-Za-z0-9*])HI\*A?BK:[A-Za-z0-9]")),
    ("PHI tier 1: X12 CLM segment with a claim id and amount",
     re.compile(r"(?<![A-Za-z0-9*])CLM\*[^*~\s]+\*\d+(?:\.\d+)?(?![A-Za-z0-9])")),
]

_HL7 = re.compile(r"^(?:PID|NK1)\|[^|]*\|")

_FHIR_PATIENT = re.compile(r'"resourceType"\s*:\s*"Patient"')
_FHIR_KEY = re.compile(r'"(?:identifier|birthDate|name)"\s*:')
_FHIR_WINDOW = 20

R_SSN = "PHI tier 1: US Social Security number"
R_MBI = "PHI tier 1: Medicare Beneficiary Identifier"
R_HL7 = "PHI tier 1: HL7 v2 PID or NK1 segment"
R_FHIR = "PHI tier 1: FHIR Patient resource with identifying data"


def _ssn_issued(area, group, serial):
    return not (
        area == "000" or area == "666" or area[0] == "9"
        or group == "00" or serial == "0000"
    )

# ----------------------------------------------------------------- tier 2 --

_MONTH = (
    r"(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|"
    r"Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|"
    r"Dec(?:ember)?)"
)
_DATE = (
    r"(?:\d{4}-\d{2}-\d{2}(?!\d)"
    r"|\d{1,2}[/.-]\d{1,2}[/.-]\d{2,4}(?!\d)"
    r"|\d{8}(?!\d)"
    r"|" + _MONTH + r"\.?\s+\d{1,2}(?:st|nd|rd|th)?,?\s+\d{4}(?!\d)"
    r"|\d{1,2}(?:st|nd|rd|th)?\s+(?:of\s+)?" + _MONTH + r"\.?,?\s+\d{4}(?!\d))"
)

_ID_ANCHOR = re.compile(
    r"(?i)(?<![A-Za-z0-9])(?:MRN(?![A-Za-z])"
    r"|medical\s+record\s*(?:number|no\.?|#)"
    r"|(?:member|subscriber|patient)\s*(?:id|number|no\.?|#)(?![A-Za-z])"
    r"|account\s*#"
    r"|claim\s*(?:#|id(?![A-Za-z])))"
    r"[\s:=#]{0,3}(?=[A-Za-z0-9-]*[0-9])[A-Za-z0-9-]{5,}"
)
_DOB_ANCHOR = re.compile(
    r"(?i)(?<![A-Za-z0-9])(?:D\.?O\.?B\.?(?![A-Za-z])|date\s+of\s+birth"
    r"|birth\s*date|born(?:\s+on)?(?![A-Za-z]))"
    r"[\s:=\-]{0,4}(?<![0-9])" + _DATE
)

_ICD = re.compile(
    r"(?<![A-Za-z0-9])[A-TV-Z][0-9][0-9AB]\.?[A-Z0-9]{0,4}(?![A-Za-z0-9]|\.[A-Za-z0-9])"
)
_DX_WORD = re.compile(
    r"(?i)(?<![A-Za-z0-9])(?:diagnosed|diagnosis|diagnoses|admitted|"
    r"discharged|prescribed)(?![A-Za-z0-9])"
)
_NAME_LABEL = re.compile(
    r"(?i:(?<![A-Za-z0-9])(?:(?:patient|member|subscriber|insured)\s*:"
    r"|patient\s+name|member\s+name))"
    r"|(?<![A-Za-z0-9])(?:Mr|Mrs|Ms|Miss)\.?\s+[A-Z][a-z]+"
)

_WINDOW = 1  # lines on each side of the anchor: a window of three


def _lines(text):
    return re.split(r"\r\n|\n|\r", text)


def _tier1(lines):
    hits = []
    for i, line in enumerate(lines, 1):
        for m in _SSN_DASHED.finditer(line):
            if _ssn_issued(*m.groups()):
                hits.append((i, R_SSN))
                break
        else:
            if _SSN_LABELLED.search(line):
                hits.append((i, R_SSN))
        if _MBI.search(line):
            hits.append((i, R_MBI))
        for rule, rx in _X12:
            if rx.search(line):
                hits.append((i, rule))
        if _HL7.search(line):
            hits.append((i, R_HL7))
        if _FHIR_PATIENT.search(line):
            lo, hi = max(0, i - 1 - _FHIR_WINDOW), min(len(lines), i + _FHIR_WINDOW)
            if any(_FHIR_KEY.search(lines[j]) for j in range(lo, hi)):
                hits.append((i, R_FHIR))
    return hits


def _spans(rx, line):
    return [(m.start(), m.end()) for m in rx.finditer(line)]


def _tier2(lines):
    # anchors and signals as (line number, kind, start, end)
    anchors, signals = [], []
    for i, line in enumerate(lines, 1):
        for s, e in _spans(_ID_ANCHOR, line):
            anchors.append((i, "identifier", s, e))
        for s, e in _spans(_DOB_ANCHOR, line):
            anchors.append((i, "date of birth", s, e))
        for s, e in _spans(_ICD, line):
            signals.append((i, "ICD-10-CM code", s, e))
        for s, e in _spans(_DX_WORD, line):
            signals.append((i, "diagnosis word", s, e))
        for s, e in _spans(_NAME_LABEL, line):
            signals.append((i, "person-name label", s, e))
    if not anchors:
        return []
    hits = []
    for a in anchors:
        best = None
        for other in signals + anchors:
            if other is a or abs(other[0] - a[0]) > _WINDOW:
                continue
            if other[0] == a[0] and other[2] < a[3] and a[2] < other[3]:
                continue  # inside the anchor's own text
            key = (abs(other[0] - a[0]), other[0], other[2])
            if best is None or key < best[0]:
                best = (key, other[1])
        if best:
            hits.append((a[0], "PHI tier 2: %s near %s" % (a[1], best[1])))
    return hits


def scan(text):
    """Return [(line, rule)] for every hit in text, sorted, without duplicates."""
    lines = _lines(text)
    return sorted(set(_tier1(lines) + _tier2(lines)))


def find(text):
    """Return the distinct rules that hit in text, in order of first hit."""
    seen = []
    for _, rule in scan(text):
        if rule not in seen:
            seen.append(rule)
    return seen
