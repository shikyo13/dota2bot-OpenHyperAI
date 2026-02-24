#!/usr/bin/env python3
"""
Update neutrals_data.lua for patch 7.40 neutral item tier changes.
- Removes cycled-out items, redistributing their weight proportionally
- Moves items between tiers (preserving their weight)
- Adds new items with a default weight (taken proportionally from existing items)
"""

import re
import sys

INPUT = r"D:\Dev\Projects\Dota2AI\bots\FretBots\neutrals_data.lua"
OUTPUT = INPUT  # overwrite in place

# Items to REMOVE from each tier (cycled out in 7.40)
REMOVE = {
    1: {'item_sisters_shroud', 'item_spark_of_courage', 'item_rippers_lash'},
    2: {'item_misericorde'},
    3: {'item_gale_guard'},
    4: {'item_pyrrhic_cloak', 'item_magnifying_monocle', 'item_outworld_staff'},
    5: {'item_helm_of_the_undying'},
}

# Items to MOVE between tiers: (item_name, from_tier, to_tier)
MOVES = [
    ('item_unrelenting_eye', 5, 3),
    ('item_dezun_bloodrite', 4, 5),
]

# New items to ADD per tier (with a default weight of ~5% each, taken from existing)
ADD_NEW = {
    1: ['item_ash_legion_shield', 'item_weighted_dice', 'item_duelist_gloves'],
    2: ['item_defiant_shell'],
    3: [],  # unrelenting_eye comes via MOVE
    4: ['item_flayers_bota', 'item_idol_of_screeauk', 'item_metamorphic_mandible', 'item_rattlecage'],
    5: ['item_riftshadow_prism'],
}

DEFAULT_NEW_WEIGHT = 5.0  # % weight for each new item


def parse_tier_dict(s):
    """Parse a Lua dict like {['item_x'] = 12.34, ['item_y'] = 56.78} into Python dict."""
    result = {}
    for m in re.finditer(r"\['([^']+)'\]\s*=\s*([0-9.]+)", s):
        result[m.group(1)] = float(m.group(2))
    return result


def format_tier_dict(d):
    """Format Python dict back to Lua dict string."""
    parts = []
    for k, v in d.items():
        parts.append(f"['{k}'] = {v:.2f}")
    return '{' + ', '.join(parts) + '}'


def redistribute_remove(items, to_remove):
    """Remove items and redistribute their weight proportionally."""
    removed_weight = sum(items.get(k, 0) for k in to_remove)
    remaining = {k: v for k, v in items.items() if k not in to_remove}
    if not remaining:
        return remaining
    total_remaining = sum(remaining.values())
    if total_remaining > 0 and removed_weight > 0:
        scale = (total_remaining + removed_weight) / total_remaining
        remaining = {k: v * scale for k, v in remaining.items()}
    return remaining


def add_new_items(items, new_items, default_weight=DEFAULT_NEW_WEIGHT):
    """Add new items, taking weight proportionally from existing items."""
    if not new_items:
        return items
    # Filter out items that already exist
    actually_new = [i for i in new_items if i not in items]
    if not actually_new:
        return items
    total_new_weight = default_weight * len(actually_new)
    total_current = sum(items.values())
    if total_current > 0:
        scale = (total_current - total_new_weight) / total_current
        if scale < 0.5:
            scale = 0.5  # don't shrink too much
        items = {k: v * scale for k, v in items.items()}
    for item in actually_new:
        items[item] = default_weight
    return items


def normalize_to_100(items):
    """Normalize all weights to sum to ~100."""
    total = sum(items.values())
    if total > 0:
        items = {k: (v / total) * 100 for k, v in items.items()}
    return items


def process_tier(tier_num, items):
    """Process a single tier dict: remove, move-out, add moved-in, add new, normalize."""
    # Step 1: Remove cycled-out items
    to_remove = REMOVE.get(tier_num, set())
    if to_remove:
        items = redistribute_remove(items, to_remove)

    # Step 2: Remove items being moved OUT of this tier
    for item_name, from_tier, to_tier in MOVES:
        if from_tier == tier_num and item_name in items:
            del items[item_name]

    # Step 3: Add items being moved INTO this tier
    for item_name, from_tier, to_tier in MOVES:
        if to_tier == tier_num and item_name not in items:
            items[item_name] = DEFAULT_NEW_WEIGHT

    # Step 4: Add brand new items
    new_items = ADD_NEW.get(tier_num, [])
    if new_items:
        items = add_new_items(items, new_items)

    # Step 5: Normalize to sum to ~100
    items = normalize_to_100(items)

    # Round to 2 decimal places
    items = {k: round(v, 2) for k, v in items.items()}

    return items


def process_file(content):
    """Process the entire neutrals_data.lua file."""
    # Match tier entries like: [1] = {['item_x'] = 12.34, ...},
    # within ['neutral'] blocks

    lines = content.split('\n')
    output_lines = []
    in_neutral = False

    for line in lines:
        # Detect entering/leaving neutral block
        if "['neutral']" in line:
            in_neutral = True
            output_lines.append(line)
            continue
        if "['enhancement']" in line:
            in_neutral = False
            output_lines.append(line)
            continue

        if in_neutral:
            # Check if this line has a tier dict
            m = re.match(r'^(\s*\[(\d)\]\s*=\s*)\{(.+)\}(,?\s*)$', line)
            if m:
                prefix = m.group(1)
                tier_num = int(m.group(2))
                dict_str = '{' + m.group(3) + '}'
                suffix = m.group(4)

                items = parse_tier_dict(dict_str)
                items = process_tier(tier_num, items)
                new_dict = format_tier_dict(items)
                output_lines.append(f"{prefix}{new_dict}{suffix}")
                continue

        output_lines.append(line)

    return '\n'.join(output_lines)


def main():
    with open(INPUT, 'r', encoding='utf-8') as f:
        content = f.read()

    result = process_file(content)

    with open(OUTPUT, 'w', encoding='utf-8') as f:
        f.write(result)

    print(f"Updated {OUTPUT}")
    print("Changes applied:")
    print(f"  Removed: {sum(len(v) for v in REMOVE.values())} items across tiers")
    print(f"  Moved: {len(MOVES)} items between tiers")
    print(f"  Added: {sum(len(v) for v in ADD_NEW.values())} new items")


if __name__ == '__main__':
    main()
