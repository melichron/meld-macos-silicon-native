# SPDX-License-Identifier: GPL-2.0-or-later
from bisect import bisect_right
import json
import os
import stat
import sys

from myers import InlineMyersSequenceMatcher, MyersSequenceMatcher


def chunks(left, right):
    # Meld's Differ uses pane 1 as the base, including for two-pane diffs.
    matcher = MyersSequenceMatcher(None, right, left)
    result = []
    for op in matcher.get_difference_opcodes():
        left_marks, right_marks = {}, {}
        if op.tag == "replace":
            left_marks, right_marks = inline_marks(left, right, op)
        result.append(dict(leftStart=op.start_b, leftEnd=op.end_b,
                           rightStart=op.start_a, rightEnd=op.end_a,
                           leftMarks=left_marks, rightMarks=right_marks))
    return result


def inline_marks(left, right, op):
    # Compare the same multi-line buffer slices as Meld, including an LF
    # when a block ends at the beginning of another line.
    sides = [(right, op.start_a, op.end_a), (left, op.start_b, op.end_b)]
    texts = ["\n".join(lines[start:end]) + ("\n" if end < len(lines) else "")
             for lines, start, end in sides]
    if sum(map(len, texts)) > 20000:
        return {}, {}

    starts = []
    for lines, begin, end in sides:
        offsets = [0]
        for line in lines[begin:end]:
            offsets.append(offsets[-1] + len(line) + 1)
        starts.append(offsets)

    marks = [{}, {}]
    for match in InlineMyersSequenceMatcher(None, *texts).get_opcodes():
        if match.tag == "equal":
            at_start = match.start_a == match.start_b == 0
            at_end = match.end_a == len(texts[0]) and match.end_b == len(texts[1])
            if at_start or at_end or match.end_a - match.start_a >= 3:
                continue
        for side, (lo, hi) in enumerate(((match.start_a, match.end_a),
                                         (match.start_b, match.end_b))):
            offsets = starts[side]
            row = bisect_right(offsets, lo) - 1
            while lo < hi and row + 1 < len(offsets):
                stop = min(hi, offsets[row + 1] - 1)
                if lo < stop:
                    marks[side].setdefault(row, []).append(
                        dict(start=lo - offsets[row], end=stop - offsets[row]))
                row += 1
                lo = offsets[row]
    return marks[1], marks[0]


def inventory(root, include_git):
    entries = {}

    def visit(path):
        try:
            with os.scandir(path) as items:
                for item in items:
                    if not include_git and item.name == ".git":
                        continue
                    rel = os.path.relpath(item.path, root)
                    try:
                        mode = item.stat(follow_symlinks=False).st_mode
                        if stat.S_ISDIR(mode):
                            entries[rel] = "dir"
                            visit(item.path)
                        elif stat.S_ISREG(mode):
                            entries[rel] = "file"
                        elif stat.S_ISLNK(mode):
                            entries[rel] = "link"
                        else:
                            entries[rel] = "special"
                    except OSError as err:
                        entries[rel] = str(err)
        except OSError as err:
            if path == root:
                raise
            entries[os.path.relpath(path, root)] = str(err)
    visit(root)
    return entries


def equal_files(a, b):
    with open(a, "rb") as left, open(b, "rb") as right:
        if os.fstat(left.fileno()).st_size != os.fstat(right.fileno()).st_size:
            return False
        while True:
            block = left.read(262144)
            if block != right.read(262144):
                return False
            if not block:
                return True


def folders(left, right, include_git=False):
    a, b = inventory(left, include_git), inventory(right, include_git)
    result = []
    for key in sorted(a.keys() | b.keys(), key=lambda p: p.split(os.sep)):
        x, y = a.get(key), b.get(key)
        paths = [os.path.join(root, key) for root in (left, right)]
        editable = False
        if any(k not in (None, "file", "dir", "link", "special") for k in (x, y)):
            status = "Ошибка доступа"
        elif x is None or y is None:
            status = "Только справа" if x is None else "Только слева"
        elif x != y:
            status = "Разные типы"
        elif x == "dir":
            status = "Совпадает"
        elif x == "special":
            status = "Спецфайл"
        else:
            try:
                equal = (equal_files(*paths) if x == "file" else
                         os.readlink(paths[0]) == os.readlink(paths[1]))
                status = "Совпадает" if equal else "Изменён"
                editable = x == "file"
            except OSError:
                status = "Ошибка чтения"
        result.append(dict(path=key, status=status, editable=editable, left=x, right=y))
    by_path = {entry["path"]: entry for entry in result}
    for entry in reversed(result):
        parent = by_path.get(os.path.dirname(entry["path"]))
        if entry["status"] != "Совпадает" and parent and parent["status"] == "Совпадает":
            parent["status"] = "Изменён"
    return result


if __name__ == "__main__":
    args = json.load(sys.stdin)
    result = {"diff": chunks, "folders": folders}[sys.argv[1]](*args)
    json.dump(result, sys.stdout, ensure_ascii=True)
