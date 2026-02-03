#!/usr/bin/env python3
import base64
import re
import sys
import xml.etree.ElementTree as ET


def rtf_to_text(rtf: str) -> str:
    skip_groups = {"fonttbl", "colortbl", "stylesheet", "expandedcolortbl"}

    def strip_groups(text: str) -> str:
        out = []
        i = 0
        length = len(text)
        while i < length:
            ch = text[i]
            if ch == "{":
                # detect group control word
                word = ""
                j = i + 1
                if j < length and text[j] == "\\":
                    k = j + 1
                    if k < length and text[k] == "*":
                        k += 1
                        if k < length and text[k] == "\\":
                            k += 1
                    start = k
                    while k < length and text[k].isalpha():
                        k += 1
                    word = text[start:k]
                if word in skip_groups:
                    depth = 1
                    i += 1
                    while i < length and depth > 0:
                        if text[i] == "{":
                            depth += 1
                        elif text[i] == "}":
                            depth -= 1
                        i += 1
                    continue
            out.append(ch)
            i += 1
        return "".join(out)

    rtf = strip_groups(rtf)
    # Decode common RTF escape sequences into plain text.
    def hex_replace(match):
        return bytes.fromhex(match.group(1)).decode("latin-1")

    def uni_replace(match):
        num = int(match.group(1))
        if num < 0:
            num += 65536
        return chr(num)

    rtf = re.sub(r"\\'([0-9a-fA-F]{2})", hex_replace, rtf)
    # RTF `\uN` may be followed by a delimiter space; consume it so it
    # does not appear as inter-character spacing in non-Latin scripts.
    rtf = re.sub(r"\\u(-?\d+)\?? ?", uni_replace, rtf)
    rtf = re.sub(r"\\par[d]? ?", "\n", rtf)
    rtf = re.sub(r"\\line ?", "\n", rtf)
    rtf = re.sub(r"{\\\*[^{}]*}", "", rtf)
    rtf = re.sub(r"\\[a-zA-Z]+-?\d* ?", "", rtf)
    rtf = rtf.replace("{", "").replace("}", "")
    rtf = rtf.replace("\\\n", "\n").replace("\\", "")
    # Normalize common smart-quote bytes to plain ASCII quotes.
    rtf = (rtf.replace("\x91", "'")
              .replace("\x92", "'")
              .replace("\x93", "\"")
              .replace("\x94", "\""))
    junk = {"irnatural", "tightenfactor0", "qc", "pard", "pardirnatural", "partightenfactor0"}
    lines = []
    for line in rtf.splitlines():
        stripped = line.strip()
        if not stripped:
            lines.append("")
            continue
        if stripped in junk:
            continue
        lines.append(stripped)
    return "\n".join(lines).strip()


def decode_rtf_base64(text: str) -> str:
    try:
        raw = base64.b64decode(text)
    except Exception:
        return ""
    try:
        rtf = raw.decode("utf-8")
    except Exception:
        rtf = raw.decode("latin-1", errors="ignore")
    return rtf_to_text(rtf)


def extract_slide_text(slide) -> str:
    parts = []
    for rtf_node in slide.findall(".//RVTextElement/NSString[@rvXMLIvarName='RTFData']"):
        decoded = decode_rtf_base64(rtf_node.text or "")
        if decoded:
            parts.append(decoded)
    return "\n".join(parts).strip()


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: extract_pro6_lyrics.py <path/to/file.pro6>", file=sys.stderr)
        return 2

    path = sys.argv[1]
    try:
        data = open(path, "rb").read()
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    try:
        root = ET.fromstring(data)
    except Exception as exc:
        print(f"error: invalid pro6 XML: {exc}", file=sys.stderr)
        return 1

    groups = root.find(".//array[@rvXMLIvarName='groups']")
    if groups is None:
        print("error: no groups found", file=sys.stderr)
        return 1

    output_blocks = []
    for group in list(groups):
        if group.tag != "RVSlideGrouping":
            continue
        name = group.attrib.get("name", "").strip()
        slides_node = group.find("./array[@rvXMLIvarName='slides']")
        if slides_node is None:
            continue

        slide_texts = []
        for slide in slides_node.findall("./RVDisplaySlide"):
            text = extract_slide_text(slide)
            if text:
                slide_texts.append(text)

        if not slide_texts:
            continue

        block_lines = []
        if name:
            block_lines.append(name)
        block_lines.append("\n\n".join(slide_texts))
        output_blocks.append("\n".join(block_lines).strip())

    print("\n\n".join(output_blocks).strip())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
