# SPDX-License-Identifier: GPL-2.0-or-later
import json
import os
import stat
import sys

from myers import MyersSequenceMatcher


def chunks(left, right):
    # Meld's Differ uses pane 1 as the base, including for two-pane diffs.
    matcher = MyersSequenceMatcher(None, right, left)
    return [[op.start_b, op.end_b, op.start_a, op.end_a]
            for op in matcher.get_difference_opcodes()]


def inventory(root):
    entries = {}

    def visit(path):
        try:
            with os.scandir(path) as items:
                for item in items:
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


def folders(left, right):
    a, b = inventory(left), inventory(right)
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
