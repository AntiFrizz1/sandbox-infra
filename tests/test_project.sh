#!/usr/bin/env bash
# Тесты определения типа проекта, пер-проектного конфига и каталога
# публикации (раздел 3 плана).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
# shellcheck source=deploy/lib/common.sh
source "$ROOT/deploy/lib/common.sh"
# shellcheck source=deploy/lib/project.sh
source "$ROOT/deploy/lib/project.sh"

SB=$(make_sandbox)
trap 'rm -rf "$SB"' EXIT
export SANDBOX_STATE_ROOT="$SB/state"

mk() { mkdir -p "$SB/$1"; printf '%s\n' "$SB/$1"; }

echo "== определение типа проекта =="
d=$(mk p-compose-yml);  : > "$d/docker-compose.yml"
assert_eq "docker-compose.yml → docker"  "docker" "$(detect_project_type "$d")"

d=$(mk p-compose-yaml); : > "$d/compose.yaml"
assert_eq "compose.yaml → docker"        "docker" "$(detect_project_type "$d")"

d=$(mk p-compose-yml2); : > "$d/compose.yml"
assert_eq "compose.yml → docker"         "docker" "$(detect_project_type "$d")"

d=$(mk p-compose-dcyaml); : > "$d/docker-compose.yaml"
assert_eq "docker-compose.yaml → docker" "docker" "$(detect_project_type "$d")"

d=$(mk p-dockerfile); : > "$d/Dockerfile"
assert_eq "одинокий Dockerfile → dockerfile-only" \
    "dockerfile-only" "$(detect_project_type "$d")"

d=$(mk p-both); : > "$d/Dockerfile"; : > "$d/docker-compose.yml"
assert_eq "Dockerfile + compose → docker" "docker" "$(detect_project_type "$d")"

d=$(mk p-node); : > "$d/package.json"
assert_eq "package.json → node"           "node"   "$(detect_project_type "$d")"

d=$(mk p-node-compose); : > "$d/package.json"; : > "$d/compose.yaml"
assert_eq "compose важнее package.json"   "docker" "$(detect_project_type "$d")"

d=$(mk p-static); : > "$d/index.html"
assert_eq "просто файлы → static"         "static" "$(detect_project_type "$d")"

echo
echo "== выбор compose-файла =="
d=$(mk p-prio); : > "$d/compose.yaml"; : > "$d/docker-compose.yml"
assert_eq "docker-compose.yml приоритетнее" \
    "docker-compose.yml" "$(find_compose_file "$d")"
d=$(mk p-none)
assert_fail "без compose-файла возвращает ошибку" find_compose_file "$d"

echo
echo "== validate_publish_dir =="
d=$(mk pub); mkdir -p "$d/public" "$d/dist" "$SB/secrets"
assert_eq   "публикует public/" "$d/public" "$(validate_publish_dir "$d" public)"
assert_eq   "публикует dist/"   "$d/dist"   "$(validate_publish_dir "$d" dist)"
assert_eq   "'.' публикует корень явно" "$d" "$(validate_publish_dir "$d" .)"

assert_fail "отвергает пустое значение"      validate_publish_dir "$d" ""
assert_fail "отвергает '..'"                 validate_publish_dir "$d" ".."
assert_fail "отвергает 'public/../..'"       validate_publish_dir "$d" "public/../.."
assert_fail "отвергает абсолютный путь"      validate_publish_dir "$d" "/etc"
assert_fail "отвергает несуществующий"       validate_publish_dir "$d" "nope"

: > "$d/afile"
assert_fail "отвергает файл вместо каталога" validate_publish_dir "$d" "afile"

ln -s "$SB/secrets" "$d/escape"
assert_fail "отвергает симлинк наружу"       validate_publish_dir "$d" "escape"

echo
echo "== симлинки, уводящие за пределы публикуемого каталога =="
d=$(mk syms); mkdir -p "$d/public/sub"
: > "$d/public/ok.txt"
ln -s ok.txt "$d/public/rel-ok.lnk"
ln -s ../public/ok.txt "$d/public/sub/up-ok.lnk"
assert_ok "внутренние симлинки разрешены" assert_no_escaping_symlinks "$d/public"

echo "секрет" > "$SB/secrets/token"
ln -s "$SB/secrets/token" "$d/public/leak.lnk"
assert_fail "симлинк наружу отвергается"  assert_no_escaping_symlinks "$d/public"
rm "$d/public/leak.lnk"

ln -s ../../../etc/passwd "$d/public/sub/rel-leak.lnk"
assert_fail "относительный симлинк наружу отвергается" \
    assert_no_escaping_symlinks "$d/public"
rm "$d/public/sub/rel-leak.lnk"

assert_ok "после удаления утечек снова чисто" assert_no_escaping_symlinks "$d/public"

echo
echo "== load_project_config: дефолты по автоопределению =="
d=$(mk c-static); : > "$d/index.html"
load_project_config c-static "$d"
assert_eq "static: тип"            "static" "$PROJECT_TYPE"
assert_eq "static: публикует public/ по умолчанию, а не корень" \
    "public" "$PROJECT_PUBLISH_DIR"
assert_eq "static: без build-команды" "" "$PROJECT_BUILD_CMD"
assert_eq "static: spa выключен"   "false" "$PROJECT_SPA"

d=$(mk c-node); : > "$d/package.json"
load_project_config c-node "$d"
assert_eq "node: тип"              "node"  "$PROJECT_TYPE"
assert_eq "node: публикует dist/"  "dist"  "$PROJECT_PUBLISH_DIR"
assert_eq "node: build-команда"    "npm run build" "$PROJECT_BUILD_CMD"

d=$(mk c-docker); : > "$d/compose.yaml"
load_project_config c-docker "$d"
assert_eq "docker: тип"            "docker" "$PROJECT_TYPE"
assert_eq "docker: compose-файл"   "compose.yaml" "$PROJECT_COMPOSE_FILE"

echo
echo "== load_project_config: конфиг в репозитории =="
d=$(mk c-repo); : > "$d/package.json"
cat > "$d/.sandbox.conf" <<'EOF'
type=node
publish_dir=build
build_cmd=npm run make
spa=true
health_url=https://example.invalid/health
EOF
load_project_config c-repo "$d"
assert_eq "тип из конфига"        "node"            "$PROJECT_TYPE"
assert_eq "publish_dir из конфига" "build"          "$PROJECT_PUBLISH_DIR"
assert_eq "build_cmd из конфига"  "npm run make"    "$PROJECT_BUILD_CMD"
assert_eq "spa из конфига"        "true"            "$PROJECT_SPA"
assert_eq "health_url из конфига" "https://example.invalid/health" "$PROJECT_HEALTH_URL"
assert_eq "источник — конфиг репозитория" "$d/.sandbox.conf" "$PROJECT_CONFIG_SOURCE"

echo
echo "== load_project_config: серверный конфиг как запасной вариант =="
d=$(mk c-srv); : > "$d/index.html"
mkdir -p "$SANDBOX_STATE_ROOT/c-srv"
printf 'type=static\npublish_dir=.\n' > "$SANDBOX_STATE_ROOT/c-srv/config"
load_project_config c-srv "$d"
assert_eq "publish_dir из серверного конфига" "." "$PROJECT_PUBLISH_DIR"
assert_eq "источник — серверный конфиг" \
    "$SANDBOX_STATE_ROOT/c-srv/config" "$PROJECT_CONFIG_SOURCE"

# Конфиг в репозитории должен побеждать серверный.
printf 'publish_dir=public\n' > "$d/.sandbox.conf"
mkdir -p "$d/public"
load_project_config c-srv "$d"
assert_eq "конфиг репозитория важнее серверного" "public" "$PROJECT_PUBLISH_DIR"

echo
echo "== load_project_config: неверные значения отвергаются =="
d=$(mk c-bad); : > "$d/index.html"
printf 'type=kubernetes\n' > "$d/.sandbox.conf"
assert_fail "неизвестный type"  load_project_config c-bad "$d"
printf 'type=static\nspa=maybe\n' > "$d/.sandbox.conf"
assert_fail "нелогическое spa"  load_project_config c-bad "$d"
printf 'type=static\npublish_dir=../..\n' > "$d/.sandbox.conf"
assert_fail "publish_dir с traversal" load_project_config c-bad "$d"

echo
echo "== конфиг не может выполнить код =="
d=$(mk c-evil); : > "$d/index.html"
printf 'type=static\npublish_dir=$(touch %s/PWNED)\n' "$SB" > "$d/.sandbox.conf"
load_project_config c-evil "$d" >/dev/null 2>&1
assert_missing "подстановка команды не выполнилась" "$SB/PWNED"

finish
