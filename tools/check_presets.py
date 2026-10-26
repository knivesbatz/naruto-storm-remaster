"""Static checks for the shader + presets (run: python tools/check_presets.py).

Fails if a preset enables a technique or sets a uniform that NS_Remaster.fx doesn't define,
if NS_Begin/NS_Finish are missing or out of order, or if an [effect] section is unknown.
ReShade itself only compiles the shader in-game; this catches preset/shader drift offline.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
FX = ROOT / "reshade-shaders" / "Shaders" / "NS_Remaster.fx"
PRESETS = sorted(ROOT.glob("NarutoStorm_*.ini"))


def main() -> int:
    src = FX.read_text(encoding="utf-8")
    techniques = set(re.findall(r"^technique\s+(\w+)", src, re.M))
    uniforms = set(re.findall(r"^uniform\s+\w+\s+(\w+)\s*<", src, re.M))
    errors = []
    assert techniques and uniforms and PRESETS, "parser found nothing - layout changed?"

    for preset in PRESETS:
        section, keys, top = None, {}, {}
        for line in preset.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith(";"):
                continue
            if line.startswith("["):
                section = line.strip("[]")
                if section != "NS_Remaster.fx":
                    errors.append(f"{preset.name}: unknown section [{section}]")
                continue
            k, _, v = line.partition("=")
            (keys if section else top)[k] = v

        enabled = [t.split("@")[0] for t in top.get("Techniques", "").split(",") if t]
        order = [t.split("@")[0] for t in top.get("TechniqueSorting", "").split(",") if t]
        for t in enabled + order:
            if t not in techniques:
                errors.append(f"{preset.name}: unknown technique {t}")
        if enabled:  # Vanilla preset enables nothing
            if enabled[0] != "NS_Begin" or enabled[-1] != "NS_Finish":
                errors.append(f"{preset.name}: NS_Begin must be first and NS_Finish last")
        if order and (order[0] != "NS_Begin" or order[-1] != "NS_Finish"):
            errors.append(f"{preset.name}: TechniqueSorting must start with NS_Begin and end with NS_Finish")
        for k in keys:
            if k not in uniforms:
                errors.append(f"{preset.name}: unknown setting {k}")
        div = top.get("PreprocessorDefinitions", "")
        if div and not re.fullmatch(r"NS_EFFECT_DIV=[234]", div):
            errors.append(f"{preset.name}: unexpected PreprocessorDefinitions {div}")

    for e in errors:
        print("FAIL", e)
    print(f"{len(PRESETS)} presets, {len(techniques)} techniques, {len(uniforms)} settings checked")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
