"""Split Japanese lines into (surface, hiragana reading) pieces with macOS CFStringTokenizer, the same
tokenizer + overrides the chart pipeline's ja_kana.py used to turn kanji into the chart's kana, so the
pieces line up with the chart notes. Needs Apple's /usr/bin/python3 (pyobjc). Deterministic for a given
macOS version.
stdin: JSON list of lines.  stdout: JSON list (per line) of [surface, reading] pieces; the surfaces
concatenate to the line, reading == surface for pieces without kanji."""
import json, re, sys, unicodedata
import CoreFoundation as CF
from Foundation import NSString

FIX = {"私": "わたし", "私達": "わたしたち", "何": "なに", "今日": "きょう", "明日": "あした", "一人": "ひとり",
       "二人": "ふたり", "大人": "おとな"}
CJK = re.compile(r"[一-鿿々]")
LOC = CF.CFLocaleCreate(None, "ja")


def pieces(text):
    tok = CF.CFStringTokenizerCreate(None, text, CF.CFRangeMake(0, len(text)), CF.kCFStringTokenizerUnitWord, LOC)
    out, pos = [], 0
    while CF.CFStringTokenizerAdvanceToNextToken(tok) != CF.kCFStringTokenizerTokenNone:
        r = CF.CFStringTokenizerGetCurrentTokenRange(tok)
        surf = text[r.location:r.location + r.length]
        if r.location > pos:
            gap = text[pos:r.location]
            out.append([gap, gap])
        pos = r.location + r.length
        if CJK.search(surf):
            if surf in FIX:
                out.append([surf, FIX[surf]]); continue
            lat = CF.CFStringTokenizerCopyCurrentTokenAttribute(tok, CF.kCFStringTokenizerAttributeLatinTranscription) or ""
            h = str(NSString.stringWithString_(lat).stringByApplyingTransform_reverse_("Latin-Hiragana", False) or surf)
            out.append([surf, unicodedata.normalize("NFC", h)])
        else:
            out.append([surf, surf])
    if pos < len(text):
        out.append([text[pos:], text[pos:]])
    return out


json.dump([pieces(l) for l in json.load(sys.stdin)], sys.stdout, ensure_ascii=False)
