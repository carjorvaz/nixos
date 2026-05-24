{
  writeShellApplication,
  writeText,
  python3,
}:

let
  script = writeText "org-daily-scratch.py" ''
    #!/usr/bin/env python3
    import argparse
    import datetime as dt
    import fcntl
    import os
    import re
    import sys
    import uuid
    from pathlib import Path

    WORKBENCH_TEXT = "Messy scratch for today. This is allowed to be incomplete. It does not need to be processed to zero."
    SECTIONS = {
        "scratch": (
            "Scratch",
            "Raw thoughts, links, rambling, and active thinking go here by default.",
        ),
        "action-candidates": (
            "Action candidates",
            "Things that smell actionable but are not clarified yet. Hermes can sweep this with you one item at a time.",
        ),
        "extracted-actions": (
            "Extracted actions",
            "Only concrete actions that should be moved to gtd.org / inbox.org / tickler.org.",
        ),
    }
    SECTION_ORDER = ["scratch", "action-candidates", "extracted-actions"]

    def single_line(value):
        return re.sub(r"\s+", " ", str(value or "")).strip()

    def parse_args():
        parser = argparse.ArgumentParser(
            description="Append a raw capture to ~/org/roam/daily/YYYY-MM-DD.org under Workbench/Scratch."
        )
        parser.add_argument("text", nargs="*", help="Capture text. If omitted, stdin is used when piped.")
        parser.add_argument("--stdin", action="store_true", help="Read capture text from stdin.")
        parser.add_argument("--date", help="Target date in YYYY-MM-DD form. Defaults to today.")
        parser.add_argument("--org-dir", default=os.environ.get("ORG_DIR", "~/org"), help="Org root. Defaults to $ORG_DIR or ~/org.")
        parser.add_argument(
            "--section",
            choices=["auto"] + SECTION_ORDER,
            default="auto",
            help="Workbench subsection. auto routes todo:/next:/remind: to Action candidates; everything else to Scratch.",
        )
        parser.add_argument("--source", default=os.environ.get("ORG_DAILY_SCRATCH_SOURCE", "cli"), help="Source property to store on the capture.")
        parser.add_argument("--heading", help="Override the Org heading title.")
        parser.add_argument("--link", help="Optional URL/link to store with the capture.")
        return parser.parse_args()

    def read_capture(args):
        parts = []
        if args.text:
            parts.append(" ".join(args.text))
        if args.stdin or (not args.text and not sys.stdin.isatty()):
            parts.append(sys.stdin.read())
        text = "\n".join(part for part in parts if part is not None).strip()
        args.link = single_line(args.link) if args.link else None
        if not text and not args.link:
            raise SystemExit("No capture text provided. Pass text arguments, --link, or pipe stdin.")
        return text

    def parse_date(value):
        if value:
            try:
                return dt.date.fromisoformat(value)
            except ValueError as exc:
                raise SystemExit(f"Invalid --date {value!r}; expected YYYY-MM-DD") from exc
        return dt.date.today()

    def org_timestamp(now):
        return now.strftime("[%Y-%m-%d %a %H:%M]")

    def daily_skeleton(day):
        return (
            f":PROPERTIES:\n:ID:       {uuid.uuid4()}\n:END:\n"
            f"#+title: {day.isoformat()} {day.strftime('%A')}\n\n"
            f"* Workbench\n{WORKBENCH_TEXT}\n\n"
            f"** Scratch\n{SECTIONS['scratch'][1]}\n\n"
            f"** Action candidates\n{SECTIONS['action-candidates'][1]}\n\n"
            f"** Extracted actions\n{SECTIONS['extracted-actions'][1]}\n"
        )

    HEADING_RE = re.compile(r"^(?P<stars>\*+)\s+(?P<title>.*?)\s*$")
    TAG_SUFFIX_RE = re.compile(r"\s+:[A-Za-z0-9_@#%:.-]+:\s*$")

    def heading(line):
        match = HEADING_RE.match(line.rstrip("\n"))
        if not match:
            return None
        title = TAG_SUFFIX_RE.sub("", match.group("title")).strip()
        return len(match.group("stars")), title

    def find_heading(lines, title, level=None, start=0, end=None):
        end = len(lines) if end is None else end
        for idx in range(start, end):
            parsed = heading(lines[idx])
            if not parsed:
                continue
            parsed_level, parsed_title = parsed
            if parsed_title == title and (level is None or parsed_level == level):
                return idx
        return None

    def subtree_end(lines, idx, level):
        for pos in range(idx + 1, len(lines)):
            parsed = heading(lines[pos])
            if parsed and parsed[0] <= level:
                return pos
        return len(lines)

    def ensure_trailing_newline(lines):
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"

    def ensure_workbench(lines):
        wb_idx = find_heading(lines, "Workbench", level=1)
        if wb_idx is not None:
            return wb_idx
        ensure_trailing_newline(lines)
        if lines and lines[-1].strip():
            lines.append("\n")
        wb_idx = len(lines)
        lines.extend([f"* Workbench\n", f"{WORKBENCH_TEXT}\n", "\n"])
        return wb_idx

    def ensure_section(lines, key):
        title, description = SECTIONS[key]
        wb_idx = ensure_workbench(lines)
        wb_end = subtree_end(lines, wb_idx, 1)
        section_idx = find_heading(lines, title, level=2, start=wb_idx + 1, end=wb_end)
        if section_idx is not None:
            return section_idx

        insert_at = wb_end
        block = [f"** {title}\n", f"{description}\n"]
        if insert_at > 0 and lines[insert_at - 1].strip():
            block.insert(0, "\n")
        if insert_at < len(lines) and block[-1].strip():
            block.append("\n")
        lines[insert_at:insert_at] = block
        return insert_at + (1 if block and block[0] == "\n" else 0)

    def ensure_all_sections(lines):
        wb_idx = ensure_workbench(lines)
        for key in SECTION_ORDER:
            ensure_section(lines, key)
        return wb_idx

    def auto_section(section, text):
        if section != "auto":
            return section
        first = text.lstrip().splitlines()[0].lower() if text.strip() else ""
        if first.startswith(("todo:", "next:", "remind:")):
            return "action-candidates"
        return "scratch"

    def clean_title(value):
        value = single_line(value)
        value = value.lstrip("* ").strip()
        if not value:
            value = "Capture"
        if len(value) > 120:
            value = value[:117].rstrip() + "..."
        return value

    def org_body_line(line):
        if not line:
            return ""
        return "  " + line

    def org_link_target(value):
        return single_line(value).replace("[", "%5B").replace("]", "%5D")

    def org_link_label(value):
        return single_line(value).replace("[", "(").replace("]", ")")

    def format_entry(text, args, section_key):
        now = dt.datetime.now().astimezone()
        raw_lines = [line.rstrip() for line in text.splitlines()]
        nonempty = [line for line in raw_lines if line.strip()]
        title_source = args.heading or (nonempty[0] if nonempty else args.link) or "Capture"
        title = clean_title(title_source)

        body_lines = []
        if raw_lines:
            remaining = raw_lines[1:] if not args.heading else raw_lines
            if remaining:
                body_lines.extend(org_body_line(line) for line in remaining)
        safe_link = org_link_target(args.link) if args.link else ""
        if safe_link:
            if body_lines and body_lines[-1] != "":
                body_lines.append("")
            link_label = org_link_label(args.heading or (nonempty[0] if nonempty else safe_link))
            body_lines.append(f"  [[{safe_link}][{link_label}]]")

        properties = [
            ":PROPERTIES:",
            f":CREATED: {org_timestamp(now)}",
            f":SOURCE: {single_line(args.source) or 'cli'}",
        ]
        if safe_link:
            properties.append(f":URL: {safe_link}")
        if section_key != "scratch":
            properties.append(f":ROUTED_TO: {SECTIONS[section_key][0]}")
        properties.append(":END:")

        entry = ["", f"*** {title}"]
        entry.extend(properties)
        if body_lines:
            entry.extend(body_lines)
        entry.append("")
        return [line + "\n" for line in entry]

    def append_entry(path, day, section_key, text, args):
        path.parent.mkdir(parents=True, exist_ok=True)
        lock_path = path.parent / ".org-daily-scratch.lock"
        with lock_path.open("w") as lock_file:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
            before_stat = path.stat() if path.exists() else None
            if before_stat:
                lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
            else:
                lines = daily_skeleton(day).splitlines(keepends=True)

            wb_idx = ensure_all_sections(lines)
            wb_end = subtree_end(lines, wb_idx, 1)
            section_title = SECTIONS[section_key][0]
            section_idx = find_heading(
                lines,
                section_title,
                level=2,
                start=wb_idx + 1,
                end=wb_end,
            )
            if section_idx is None:
                raise SystemExit(f"Internal error: missing section {section_title}")
            insert_at = subtree_end(lines, section_idx, 2)
            lines[insert_at:insert_at] = format_entry(text, args, section_key)
            ensure_trailing_newline(lines)
            tmp_path = path.with_suffix(path.suffix + ".tmp")
            tmp_path.write_text("".join(lines), encoding="utf-8")
            if before_stat:
                current_stat = path.stat()
                changed = (
                    current_stat.st_mtime_ns != before_stat.st_mtime_ns
                    or current_stat.st_size != before_stat.st_size
                )
                if changed:
                    tmp_path.unlink(missing_ok=True)
                    raise SystemExit(f"{path} changed while capture was being prepared; retry")
            tmp_path.replace(path)
        return path

    def main():
        args = parse_args()
        text = read_capture(args)
        day = parse_date(args.date)
        org_dir = Path(args.org_dir).expanduser()
        daily_path = org_dir / "roam" / "daily" / f"{day.isoformat()}.org"
        section_key = auto_section(args.section, text)
        append_entry(daily_path, day, section_key, text, args)
        print(f"Appended to {daily_path} :: Workbench/{SECTIONS[section_key][0]}")

    if __name__ == "__main__":
        main()
  '';
in
writeShellApplication {
  name = "org-daily-scratch";

  runtimeInputs = [ python3 ];

  text = ''
    exec python3 ${script} "$@"
  '';
}
