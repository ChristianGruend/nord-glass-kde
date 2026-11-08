#!/usr/bin/env bash
# Nord Glass for KDE Plasma 6 — https://github.com/ChristianGruend/nord-glass-kde
#
#   ./install.sh                     install everything that fits this system
#   ./install.sh --only blur,rules   only some parts
#   ./install.sh --skip kitty        everything except some parts
#   ./install.sh --dry-run           show what would happen, change nothing
#   ./install.sh --uninstall         restore the backup taken before the first install
#
# Parts: kvantum · colors · blur · rules · glow · kitty
# Settings: nord-glass.conf (opacity, blur, app list). Idempotent — run again after editing it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STATE="${XDG_DATA_HOME:-$HOME/.local/share}/nord-glass"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}"

c_ok=$'\e[38;2;163;190;140m'; c_info=$'\e[38;2;136;192;208m'; c_warn=$'\e[38;2;235;203;139m'
c_err=$'\e[38;2;191;97;106m'; c_dim=$'\e[90m'; c_off=$'\e[0m'
ok()   { printf '%s✓%s %s\n' "$c_ok" "$c_off" "$*"; }
info() { printf '%s•%s %s\n' "$c_info" "$c_off" "$*"; }
warn() { printf '%s!%s %s\n' "$c_warn" "$c_off" "$*"; }
die()  { printf '%s✗%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }

DRY=0; MODE=install; ONLY=""; SKIP=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)   DRY=1 ;;
        --uninstall) MODE=uninstall ;;
        --only)      ONLY="$2"; shift ;;
        --skip)      SKIP="$2"; shift ;;
        -h|--help)   sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           die "unknown option: $1 (see --help)" ;;
    esac
    shift
done

want() {
    [ -n "$ONLY" ] && [[ ",$ONLY," != *",$1,"* ]] && return 1
    [[ ",$SKIP," == *",$1,"* ]] && return 1
    return 0
}
run() { if [ "$DRY" = 1 ]; then printf '%s  would run:%s %s\n' "$c_dim" "$c_off" "$*"; else "$@"; fi; }

# ── Settings (defaults, then nord-glass.conf) ───────────────────────────────────────────────────
BLUR_STRENGTH=3; REFRACTION=4; CORNER_RADIUS=14
KVANTUM_WINDOW_OPACITY=50; KVANTUM_MENU_OPACITY=30
GLOW_COLOR="136,192,208"; GLOW_STRENGTH=70; GLOW_SIZE=ShadowSmall
APPS=("firefox:88:78" "org.kde.dolphin:90:80"); BLUR_ONLY=(kitty); KITTY_OPACITY=0.42
# shellcheck source=nord-glass.conf
[ -f "$HERE/nord-glass.conf" ] && . "$HERE/nord-glass.conf"

# ── Environment ─────────────────────────────────────────────────────────────────────────────────
command -v kwriteconfig6 >/dev/null || die "kwriteconfig6 not found — Nord Glass needs KDE Plasma 6."
QDBUS=$(command -v qdbus6 || command -v qdbus || true)
kw()  { run kwriteconfig6 --file "$1" --group "$2" --key "$3" "$4"; }
kr()  { kreadconfig6 --file "$1" --group "$2" --key "$3" 2>/dev/null || true; }
kwin_reload() {
    [ -n "$QDBUS" ] || return 0
    # twice: freshly written window rules sometimes only apply on the second reload
    run "$QDBUS" org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
    [ "$DRY" = 1 ] || sleep 1
    run "$QDBUS" org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
}

has_better_blur() {
    local d
    for d in /usr/lib/qt6/plugins /usr/lib64/qt6/plugins /usr/lib/x86_64-linux-gnu/qt6/plugins \
             "$HOME/.local/lib/qt6/plugins"; do
        [ -e "$d/kwin/effects/plugins/better_blur_dx.so" ] && return 0
    done
    return 1
}

BACKUP_FILES=(kwinrc kwinrulesrc breezerc kdeglobals Kvantum/kvantum.kvconfig kitty/kitty.conf)

backup() {
    [ -d "$STATE/backup" ] && { info "backup from first install kept: $STATE/backup"; return; }
    [ "$DRY" = 1 ] && { info "would back up: ${BACKUP_FILES[*]}"; return; }
    mkdir -p "$STATE/backup"
    local f
    for f in "${BACKUP_FILES[@]}"; do
        if [ -f "$CFG/$f" ]; then mkdir -p "$STATE/backup/$(dirname "$f")"; cp -a "$CFG/$f" "$STATE/backup/$f"
        else echo "$f" >> "$STATE/backup/absent"; fi   # did not exist → delete again on uninstall
    done
    kr kdeglobals General ColorScheme > "$STATE/backup/colorscheme"
    kr kdeglobals KDE widgetStyle     > "$STATE/backup/widgetstyle"
    ok "backup: $STATE/backup"
}

# ── Uninstall ───────────────────────────────────────────────────────────────────────────────────
if [ "$MODE" = uninstall ]; then
    [ -d "$STATE/backup" ] || die "no backup found in $STATE/backup — nothing to restore."
    warn "restoring ${BACKUP_FILES[*]} from the backup taken before the first install."
    warn "changes you made to these files since then are lost."
    for f in "${BACKUP_FILES[@]}"; do
        if [ -f "$STATE/backup/$f" ]; then run cp -a "$STATE/backup/$f" "$CFG/$f"; fi
    done
    while read -r f; do [ -n "$f" ] && run rm -f "$CFG/$f"; done < <(cat "$STATE/backup/absent" 2>/dev/null)
    prev=$(cat "$STATE/backup/colorscheme" 2>/dev/null || true)
    [ -n "$prev" ] && command -v plasma-apply-colorscheme >/dev/null && run plasma-apply-colorscheme "$prev" >/dev/null || true
    run rm -rf "$CFG/Kvantum/NordGlass" "$HOME/.local/share/color-schemes/NordGlass.colors" "$CFG/kitty/nord-glass.conf"
    [ "$DRY" = 1 ] || mv "$STATE/backup" "$STATE/backup.restored-$(date +%Y%m%d-%H%M%S)"
    kwin_reload
    ok "Nord Glass removed. Restart open apps (and log out once) to drop the Kvantum style everywhere."
    exit 0
fi

# ── Install ─────────────────────────────────────────────────────────────────────────────────────
printf '\n%s  Nord Glass%s  %sfor KDE Plasma 6%s\n\n' "$c_info" "$c_off" "$c_dim" "$c_off"
[ "$DRY" = 1 ] && info "dry run — nothing is changed"
case "${XDG_SESSION_TYPE:-}" in
    wayland) ;; x11) info "X11 session: works, but Better Blur DX's forced blur is designed for Wayland" ;;
esac
backup

if want kvantum; then
    if command -v kvantummanager >/dev/null || [ -d /usr/share/Kvantum ]; then
        run mkdir -p "$CFG/Kvantum"
        run rm -rf "$CFG/Kvantum/NordGlass"
        run cp -r "$HERE/kvantum/NordGlass" "$CFG/Kvantum/NordGlass"
        if [ "$DRY" = 0 ]; then
            sed -i -E "s/^reduce_window_opacity=.*/reduce_window_opacity=$KVANTUM_WINDOW_OPACITY/;
                       s/^reduce_menu_opacity=.*/reduce_menu_opacity=$KVANTUM_MENU_OPACITY/" \
                "$CFG/Kvantum/NordGlass/NordGlass.kvconfig"
        fi
        kw Kvantum/kvantum.kvconfig General theme NordGlass
        kw kdeglobals KDE widgetStyle kvantum
        ok "Kvantum theme NordGlass (window opacity -$KVANTUM_WINDOW_OPACITY%) — restart apps to see it"
    else
        warn "Kvantum not installed — skipping the Qt widget style (install package 'kvantum', then re-run)"
    fi
fi

if want colors; then
    run mkdir -p "$HOME/.local/share/color-schemes"
    run cp "$HERE/color-schemes/NordGlass.colors" "$HOME/.local/share/color-schemes/NordGlass.colors"
    if command -v plasma-apply-colorscheme >/dev/null; then
        run plasma-apply-colorscheme NordGlass >/dev/null || true
        ok "color scheme NordGlass applied"
    else
        warn "plasma-apply-colorscheme missing — pick NordGlass in System Settings → Colors"
    fi
fi

# Class list for forced blur: every app with a rule plus the blur-only apps
classes=()
for a in "${APPS[@]}"; do classes+=("${a%%:*}"); done
classes+=("${BLUR_ONLY[@]}")

if want blur; then
    if has_better_blur; then
        G=Effect-better-blur-dx   # sic: the effect reads the HYPHENATED group, the plugin id uses underscores
        kw kwinrc Plugins better_blur_dxEnabled true
        kw kwinrc Plugins blurEnabled false
        kw kwinrc Plugins contrastEnabled true
        kw kwinrc $G BlurMatching true
        kw kwinrc $G BlurNonMatching false
        kw kwinrc $G BlurDecorations true
        kw kwinrc $G BlurDocks true
        kw kwinrc $G BlurMenus true
        kw kwinrc $G BlurStrength "$BLUR_STRENGTH"
        kw kwinrc $G Brightness 100
        kw kwinrc $G Contrast 120
        kw kwinrc $G Saturation 200
        kw kwinrc $G CornerRadius "$CORNER_RADIUS"
        kw kwinrc $G RefractionMode 0
        kw kwinrc $G RefractionStrength "$REFRACTION"
        kw kwinrc $G RefractionEdgeSize 8
        kw kwinrc $G RefractionCornerRadius "$CORNER_RADIUS"
        kw kwinrc $G RefractionRGBFringing 0
        # WindowClasses is a list with a literal "\n" separator — kwriteconfig6 would escape it.
        # Merge with what is already there instead of overwriting the user's list.
        if [ "$DRY" = 0 ]; then
            python3 - "$CFG/kwinrc" "${classes[@]}" <<'PY'
import re, sys
path, new = sys.argv[1], sys.argv[2:]
s = open(path).read()
m = re.search(r'^\[Effect-better-blur-dx\]\n((?:[^\[\n][^\n]*\n)*)', s, re.M)
body = m.group(1)
old = re.search(r'^WindowClasses=(.*)$', body, re.M)
have = [c for c in (old.group(1).split(r'\n') if old else []) if c]
merged = have + [c for c in new if c not in have]
body = re.sub(r'^WindowClasses=.*\n', '', body, flags=re.M) + "WindowClasses=" + r"\n".join(merged) + "\n"
open(path, 'w').write(s[:m.start(1)] + body + s[m.end(1):])
PY
        fi
        ok "Better Blur DX: strength $BLUR_STRENGTH, refraction $REFRACTION, forced on ${#classes[@]} app classes"
        if [ -n "$QDBUS" ] && [ "$DRY" = 0 ]; then   # the effect re-reads its config only on reload
            "$QDBUS" org.kde.KWin /Effects org.kde.kwin.Effects.unloadEffect better_blur_dx >/dev/null 2>&1 || true
            "$QDBUS" org.kde.KWin /Effects org.kde.kwin.Effects.loadEffect better_blur_dx >/dev/null 2>&1 || true
        fi
    else
        kw kwinrc Plugins blurEnabled true
        kw kwinrc Plugins contrastEnabled true
        kw kwinrc Effect-blur BlurStrength "$BLUR_STRENGTH"
        warn "Better Blur DX not found — using the stock KWin blur."
        info "  Stock blur only blurs apps that ask for it (Kvantum apps, kitty). Other transparent"
        info "  windows stay unblurred. For blur everywhere + refraction install Better Blur DX:"
        info "  https://github.com/xarblu/kwin-effects-better-blur-dx  (Arch AUR: kwin-effects-better-blur-dx-git)"
    fi
fi

if want rules; then
    order=""
    for a in "${APPS[@]}"; do
        IFS=: read -r cls act inact <<<"$a"
        g="nord-glass-$cls"
        kw kwinrulesrc "$g" Description "Nord Glass: $cls"
        kw kwinrulesrc "$g" wmclass "$cls"
        kw kwinrulesrc "$g" wmclassmatch 1
        kw kwinrulesrc "$g" opacityactive "$act"
        kw kwinrulesrc "$g" opacityactiverule 2
        kw kwinrulesrc "$g" opacityinactive "$inact"
        kw kwinrulesrc "$g" opacityinactiverule 2
        order="${order:+$order,}$g"
    done
    # keep every rule that already exists, append ours once
    existing=$(kr kwinrulesrc General Order)
    merged="$existing"
    for g in ${order//,/ }; do [[ ",$existing," == *",$g,"* ]] || merged="${merged:+$merged,}$g"; done
    kw kwinrulesrc General Order "$merged"
    kw kwinrulesrc General count "$(tr ',' '\n' <<<"$merged" | grep -c .)"
    ok "window rules: ${#APPS[@]} apps translucent (edit APPS in nord-glass.conf)"
fi

if want glow; then
    if [ "$(kr kwinrc org.kde.kdecoration2 library)" = "org.kde.breeze" ] || [ -z "$(kr kwinrc org.kde.kdecoration2 library)" ]; then
        kw breezerc Common ShadowColor "$GLOW_COLOR"
        kw breezerc Common ShadowSize "$GLOW_SIZE"
        kw breezerc Common ShadowStrength "$GLOW_STRENGTH"
        kw breezerc Common OutlineIntensity OutlineLow
        ok "glow: Frost shadow on Breeze (strength $GLOW_STRENGTH)"
    else
        info "window decoration is not Breeze — skipping the glow"
    fi
fi

if want kitty; then
    if command -v kitty >/dev/null; then
        run mkdir -p "$CFG/kitty"
        run cp "$HERE/kitty/nord-glass.conf" "$CFG/kitty/nord-glass.conf"
        [ "$DRY" = 0 ] && sed -i -E "s/^background_opacity .*/background_opacity $KITTY_OPACITY/" "$CFG/kitty/nord-glass.conf"
        if ! grep -qx 'include nord-glass.conf' "$CFG/kitty/kitty.conf" 2>/dev/null; then
            if [ "$DRY" = 1 ]; then info "would append 'include nord-glass.conf' to kitty.conf"
            else printf '\n# Nord Glass (https://github.com/ChristianGruend/nord-glass-kde) — keep last\ninclude nord-glass.conf\n' >> "$CFG/kitty/kitty.conf"; fi
        fi
        if [ "$DRY" = 0 ]; then pkill -USR1 -x kitty 2>/dev/null || true; fi   # live reload
        ok "kitty: Nord Glass colors, opacity $KITTY_OPACITY"
    else
        info "kitty not installed — skipping"
    fi
fi

kwin_reload
printf '\n'
ok "done. Restart open Qt/KDE apps once so Kvantum picks up the theme."
info "tweak: nord-glass.conf → ./install.sh · undo: ./install.sh --uninstall"
info "wallpaper: tools/nebula-wallpaper.py (one generated Nord nebula across all monitors)"
