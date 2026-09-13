#!/usr/bin/env python3
# Regression check for companion/combat.lua's mq.event patterns.
#
# Translates each mq.event pattern (#N# capture, #*# wildcard) to an anchored,
# case-insensitive regex and replays real EQ logs, reporting in-scope coverage
# and any line that matches more than one pattern (double-count risk).
#
# Keep the PATTERNS list below in sync with combat.lua:registerEvents(). Run:
#   python validate_patterns.py B:/eq/logs/eqlog_Foo_server.txt [maxlines]
#
# "In-scope" = this character's outgoing damage, pet/group damage, and incoming
# to me. Out-of-scope lines (other players' heals, DoTs on others printed with
# no caster, unattributable frost DS) are excluded from the denominator.

import re, sys, collections

AUTO = "hit slash crush pierce punch bite claw gore maul slam smash sting slice strike rend shoot".split()
SKILL = ["backstab", "bash", "kick", "frenzy"]


def plural(v):
    if re.search(r'sh$|ch$|ss$|[sxz]$', v): return v + 'es'
    if re.search(r'[^aeiou]y$', v):        return v[:-1] + 'ies'
    return v + 's'


def build_patterns():
    P = []
    for v in AUTO + SKILL:
        P.append(('my_' + v, "You %s #1# for #2# point#*# of damage#*#" % v))
    P += [
        ('my_miss',   "You try to #1# #2#, but #*#"),
        ('my_spell',  "You hit #1# for #2# point#*# of #3# damage by #4#.#*#"),
        ('my_nuke',   "You hit #1# for #2# point#*# of non-melee damage#*#"),
        ('my_dot',    "#1# has taken #2# damage from your #3#.#*#"),
        ('my_resist', "#1# resisted your #2#!#*#"),
        ('my_ds',     "#1# is #2# by YOUR #3# for #4# point#*# of non-melee damage#*#"),
        ('my_heal_over', "You healed #1# for #2# (#3#) hit points by #4#.#*#"),
        ('my_heal',   "You healed #1# for #2# hit points by #3#.#*#"),
        ('my_heal_over2', "You healed #1# for #2# (#3#) hit points.#*#"),
        ('my_heal2',  "You healed #1# for #2# hit points.#*#"),
        ('ot_nuke',   "#1# hit #2# for #3# point#*# of non-melee damage#*#"),
        ('ot_spell',  "#1# hit #2# for #3# point#*# of #4# damage by #5#.#*#"),
        ('ot_dot',    "#1# has taken #2# damage from #3# by #4#.#*#"),
        ('in_dot',    "You have taken #1# damage from #2#.#*#"),
        ('ot_ds',     "#1# is #2# by #3#'s #4# for #5# point#*# of non-melee damage#*#"),
        ('in_ds',     "YOU are #1# by #2# for #3# point#*# of non-melee damage#*#"),
    ]
    for v in AUTO + SKILL:
        P.append(('ot_' + v, "#1# %s #2# for #3# point#*# of damage#*#" % plural(v)))
    P += [
        ('in_miss',   "#1# tries to #2# YOU, but #3#"),
        ('kill_you',  "You have slain #1#!#*#"),
        ('kill_ot',   "#1# has been slain by #2#!#*#"),
        ('death',     "You have been slain by #1#!#*#"),
        ('died',      "You died.#*#"),
        ('wornoff',   "Your #1# spell has worn off.#*#"),
    ]
    return P


def to_rx(p):
    out = ['^']
    for part in re.split(r'(#\*#|#\d+#)', p):
        if part == '#*#':                   out.append('.*')
        elif re.fullmatch(r'#\d+#', part):  out.append('(.+?)')
        else:                               out.append(re.escape(part))
    return re.compile(''.join(out) + '$', re.IGNORECASE)


def is_combat(l):
    return ('points of' in l or ('taken' in l and 'damage' in l) or 'hit points' in l
            or 'been slain' in l or 'have slain' in l or 'resisted your' in l
            or ('tries to' in l and 'YOU' in l) or ('try to' in l and 'but' in l))


def out_of_scope(l):
    # my own heals ("You healed ...") are in scope now; other actors' heals are not
    return (('hit points' in l and not l.startswith('You healed'))
            or bool(re.search(r'has taken .* damage by ', l))  # DoT w/o caster (on others)
            or 'chilled to the bone' in l                      # unattributable frost DS
            or 'resistant to' in l)


LINE = re.compile(r'^\[.*?\] (.*)$')


def main():
    if len(sys.argv) < 2:
        print("usage: validate_patterns.py <logfile> [maxlines]"); return
    fn = sys.argv[1]
    ml = int(sys.argv[2]) if len(sys.argv) > 2 else None
    rx = [(n, to_rx(p)) for n, p in build_patterns()]

    inscope = 0
    gaps = collections.Counter()
    multi = collections.Counter()
    n = 0
    for raw in open(fn, encoding='utf-8', errors='replace'):
        n += 1
        if ml and n > ml: break
        m = LINE.match(raw); b = m.group(1) if m else raw.rstrip('\n')
        if not is_combat(b): continue
        hits = [nm for nm, r in rx if r.match(b)]
        if len(hits) > 1:
            multi[tuple(sorted(hits))] += 1
        if out_of_scope(b): continue
        inscope += 1
        if not hits:
            gaps[re.sub(r'\d[\d,]*', 'N', b)] += 1

    matched = inscope - sum(gaps.values())
    print(f"{fn}")
    print(f"  in-scope combat lines: {inscope}")
    print(f"  matched:               {matched} ({100 * matched / max(1, inscope):.2f}%)")
    if gaps:
        print("  in-scope GAPS:")
        for s, c in gaps.most_common(15):
            print(f"    {c:6d}  {s[:110]}")
    print("  multi-pattern matches (verify each is guarded / not double-counted):")
    if not multi:
        print("    none")
    for k, c in multi.most_common():
        print(f"    {c:6d}  {'+'.join(k)}")


if __name__ == '__main__':
    main()
