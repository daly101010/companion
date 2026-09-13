#!/usr/bin/env python3
# Static guard for the companion Lua modules. Catches the two crash classes that
# syntax-checking (luaparser parse) can't: undefined-global references (e.g. a
# leftover `colW` after a refactor) and use-before-definition of a file-scope
# local function (e.g. calling `parseModifiers` above its `local function`).
#
# Not a full type checker — a cheap pre-launch net. Run:
#   python tools/lint.py            # all companion/*.lua
#   python tools/lint.py combat.lua
#
# Exit code 1 if anything is flagged.

import sys, os, glob
from luaparser import ast, astnodes

# Names the MQ Lua runtime / ImGui / ImPlot provide, plus Lua stdlib globals.
KNOWN = {
    # lua stdlib
    'assert', 'error', 'ipairs', 'pairs', 'next', 'pcall', 'xpcall', 'print', 'select',
    'setmetatable', 'getmetatable', 'rawget', 'rawset', 'rawequal', 'tonumber', 'tostring',
    'type', 'unpack', 'require', 'collectgarbage', 'load', 'loadstring', 'dofile',
    'math', 'string', 'table', 'os', 'io', 'coroutine', 'debug', 'bit32', 'bit', '_G',
    # mq runtime
    'mq', 'printf', 'ImGui', 'ImPlot',
    # imgui enum/vector globals (used unqualified in MQ)
    'ImVec2', 'ImVec4', 'ImGuiWindowFlags', 'ImGuiCol', 'ImGuiStyleVar', 'ImGuiCond',
    'ImGuiTableFlags', 'ImGuiTableColumnFlags', 'ImGuiSelectableFlags', 'ImGuiInputTextFlags',
    'ImGuiTabBarFlags', 'ImGuiTabItemFlags', 'ImGuiTreeNodeFlags', 'ImGuiHoveredFlags',
    'ImGuiFocusedFlags', 'ImGuiChildFlags', 'ImGuiComboFlags', 'ImGuiSliderFlags',
    'ImGuiColorEditFlags', 'ImGuiDragDropFlags', 'ImGuiKey', 'ImGuiMouseButton',
    'ImPlotFlags', 'ImPlotAxisFlags', 'ImPlotLineFlags', 'ImAxis',
}


def collect_defined(tree):
    """Every name bound anywhere in the file: locals, assignment targets, function
    params, `local function`/method names, and for-loop vars. Inclusive on purpose
    (false negatives are fine; we only want to flag genuinely-unbound names)."""
    defined = set()

    def terminal_name(n):
        # the bound identifier of a function name: Name -> id; Index(v, 'foo') -> 'foo'
        if isinstance(n, astnodes.Name):
            return n.id
        if isinstance(n, astnodes.Index) and isinstance(n.idx, astnodes.Name):
            return n.idx.id
        return None

    def walk(node):
        if node is None:
            return
        if isinstance(node, list):
            for c in node:
                walk(c)
            return
        if not isinstance(node, astnodes.Node):
            return
        if isinstance(node, (astnodes.LocalAssign, astnodes.Assign)):
            for t in node.targets:
                if isinstance(t, astnodes.Name):
                    defined.add(t.id)
        if isinstance(node, astnodes.LocalFunction):
            tn = terminal_name(node.name)
            if tn:
                defined.add(tn)
        fn_types = [astnodes.Function, astnodes.LocalFunction, astnodes.AnonymousFunction]
        if hasattr(astnodes, 'Method'):
            fn_types.append(astnodes.Method)
        if isinstance(node, tuple(fn_types)):
            tn = terminal_name(getattr(node, 'name', None))
            if tn:
                defined.add(tn)
            if isinstance(getattr(node, 'name', None), astnodes.Name):
                defined.add(node.name.id)  # Method .name is the method identifier
            for a in getattr(node, 'args', []) or []:
                if isinstance(a, astnodes.Name):
                    defined.add(a.id)
        # member/field names are never bare globals — record them so method defs
        # (`DB:save`) and table keys don't read as undefined
        if isinstance(node, astnodes.Index) and isinstance(node.idx, astnodes.Name):
            defined.add(node.idx.id)
        if isinstance(node, astnodes.Invoke) and isinstance(node.func, astnodes.Name):
            defined.add(node.func.id)
        if isinstance(node, astnodes.Table):
            for fld in node.fields:
                if isinstance(fld.key, astnodes.Name):
                    defined.add(fld.key.id)
        if isinstance(node, astnodes.Method) and isinstance(getattr(node, 'method', None), astnodes.Name):
            defined.add(node.method.id)
        if isinstance(node, astnodes.Forin):
            for t in node.targets:
                if isinstance(t, astnodes.Name):
                    defined.add(t.id)
        if isinstance(node, astnodes.Fornum) and isinstance(node.target, astnodes.Name):
            defined.add(node.target.id)
        for attr in vars(node).values():
            if isinstance(attr, (astnodes.Node, list)):
                walk(attr)

    walk(tree)
    defined.add('self')  # implicit in `function T:method()`
    return defined


def _first_line(lines, pattern):
    import re
    rx = re.compile(pattern)
    for i, ln in enumerate(lines, 1):
        if ln.strip().startswith('--'):
            continue
        if rx.search(ln):
            return i
    return 0


def check_file(path):
    import re
    src = open(path, encoding='utf-8').read()
    tree = ast.parse(src)
    defined = collect_defined(tree)
    lines = src.split('\n')
    problems = []

    # 1) undefined-global references. Walk manually so we DON'T treat these as
    #    variable references: `t.field` (idx), `t:method()` (method name), and
    #    `{ name = v }` table keys. Only genuine value/call Names count.
    undefined = set()

    def walk(node):
        if node is None:
            return
        if isinstance(node, list):
            for c in node:
                walk(c)
            return
        if not isinstance(node, astnodes.Node):
            return
        if isinstance(node, astnodes.Name):
            if node.id not in defined and node.id not in KNOWN:
                undefined.add(node.id)
            return
        if isinstance(node, astnodes.Index):
            walk(node.value); return                       # skip .idx (field name)
        if isinstance(node, astnodes.Invoke):
            walk(node.source); walk(node.args); return      # skip .func (method name)
        if isinstance(node, astnodes.Table):
            for fld in node.fields:
                if not isinstance(fld.key, astnodes.Name):
                    walk(fld.key)                            # [expr] keys are refs; name keys aren't
                walk(fld.value)
            return
        for attr in vars(node).values():                    # generic: recurse all children
            if isinstance(attr, (astnodes.Node, list)):
                walk(attr)

    walk(tree)
    for name in undefined:
        ln = _first_line(lines, r'(?<![\w.:])' + re.escape(name) + r'(?![\w])')
        problems.append((ln, f"undefined name '{name}'"))

    # 2) file-scope use-before-definition of a `local function` (the crash class).
    deflines = {}
    for i, ln in enumerate(lines, 1):
        m = re.match(r'\s*local function (\w+)', ln)
        if m and m.group(1) not in deflines:
            deflines[m.group(1)] = i
    for name, dline in deflines.items():
        for i in range(1, dline):
            ln = lines[i - 1]
            if ln.strip().startswith('--'):
                continue
            if re.search(r'(?<![\w.:])' + re.escape(name) + r'\s*\(', ln):
                problems.append((i, f"'{name}' used on line {i} before its definition (line {dline})"))
                break

    seen, uniq = set(), []
    for ln, msg in sorted(problems):
        if (ln, msg) not in seen:
            seen.add((ln, msg)); uniq.append((ln, msg))
    return uniq


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    args = sys.argv[1:]
    files = [os.path.join(root, a) for a in args] if args else sorted(glob.glob(os.path.join(root, '*.lua')))
    total = 0
    for f in files:
        probs = check_file(f)
        name = os.path.basename(f)
        if probs:
            total += len(probs)
            for ln, msg in probs:
                print(f"{name}:{ln}: {msg}")
        else:
            print(f"{name}: clean")
    if total:
        print(f"\n{total} issue(s) found.")
        sys.exit(1)
    print("\nall clean.")


if __name__ == '__main__':
    main()
