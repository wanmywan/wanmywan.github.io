#!/usr/bin/env bash
# blog.sh — helper all-in-one buat blog Hugo ini.
#
#   ./scripts/blog.sh new "Judul Artikel"   bikin artikel baru (page bundle, draft)
#   ./scripts/blog.sh serve                 preview lokal (termasuk draft) di :1313
#   ./scripts/blog.sh build                 cek build produksi (tanpa deploy)
#   ./scripts/blog.sh publish <slug>        ubah draft:true -> false pada satu artikel
#   ./scripts/blog.sh deploy ["pesan"]      cek build -> commit -> push -> tunggu deploy
#                                           (auto re-trigger kalau GitHub Pages nyangkut)
#   ./scripts/blog.sh status                cek status deploy terakhir + situs live
#
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$SELF")/.."

# --- warna ---
if [ -t 1 ]; then B="\033[1m"; G="\033[32m"; Y="\033[33m"; R="\033[31m"; C="\033[36m"; N="\033[0m"; else B=""; G=""; Y=""; R=""; C=""; N=""; fi
info(){ printf "${C}▸${N} %s\n" "$*"; }
ok(){   printf "${G}✔${N} %s\n" "$*"; }
warn(){ printf "${Y}!${N} %s\n" "$*"; }
err(){  printf "${R}x${N} %s\n" "$*" >&2; }
die(){  err "$*"; exit 1; }

command -v hugo >/dev/null || die "hugo tidak ditemukan (brew install hugo)"

# owner/repo dari remote git
repo_slug(){ git remote get-url origin 2>/dev/null | sed -E 's#.*[:/]([^/]+/[^/]+)\.git#\1#'; }

# ---------- perintah ----------

cmd_new(){
  [ -n "${1:-}" ] || die "Pakai: blog.sh new \"Judul Artikel\""
  ./scripts/new-post.sh "$@"
}

cmd_serve(){
  info "Preview lokal (termasuk draft) → http://localhost:1313  (Ctrl+C untuk stop)"
  hugo server -D --buildFuture
}

cmd_build(){
  info "Build produksi (cek error)..."
  if hugo --gc --minify >/tmp/blog-build.log 2>&1; then
    ok "Build bersih. $(grep -E 'Total in' /tmp/blog-build.log | tail -1)"
    return 0
  else
    err "Build GAGAL:"; tail -15 /tmp/blog-build.log >&2; return 1
  fi
}

cmd_publish(){
  local slug="${1:-}"
  [ -n "$slug" ] || die "Pakai: blog.sh publish <slug>   (folder di content/posts/)"
  local f="content/posts/$slug/index.md"
  [ -f "$f" ] || f="content/posts/$slug.md"
  [ -f "$f" ] || die "Tidak ketemu artikel: $slug"
  sed -i '' -E 's/^draft: true/draft: false/' "$f"
  ok "draft:false → $f  (jalankan: blog.sh deploy)"
}

# tunggu run utk SHA tertentu; echo "success" / "failure" / "timeout"
wait_run(){
  local sha="$1" slug; slug="$(repo_slug)"
  local api="https://api.github.com/repos/${slug}/actions/runs?head_sha=${sha}&per_page=1"
  local n=0
  while [ $n -lt 40 ]; do
    local j; j="$(curl -s "$api")"
    if echo "$j" | grep -q '"conclusion": "success"'; then echo success; return; fi
    if echo "$j" | grep -q '"conclusion": "failure"'; then echo failure; return; fi
    if echo "$j" | grep -q '"conclusion": "cancelled"'; then echo failure; return; fi
    printf "  ${C}·${N} deploy berjalan... (%ss)\r" $((n*15)) >&2
    n=$((n+1)); sleep 15
  done
  echo timeout
}

cmd_deploy(){
  local msg="${1:-update: $(date +%Y-%m-%d\ %H:%M)}"
  cmd_build || die "Perbaiki error build dulu sebelum deploy."

  info "Commit & push..."
  git add -A
  git commit -m "$msg" >/dev/null 2>&1 || git commit --allow-empty -m "$msg" >/dev/null 2>&1
  git push origin main >/dev/null 2>&1 || die "git push gagal (cek koneksi/SSH)."
  ok "Terkirim ke GitHub."

  local slug; slug="$(repo_slug)"
  local attempt=1 max=4
  while [ $attempt -le $max ]; do
    sleep 8
    local sha; sha="$(git rev-parse HEAD)"
    info "Menunggu GitHub Actions (percobaan $attempt/$max)..."
    local res; res="$(wait_run "$sha")"
    printf "\n" >&2
    case "$res" in
      success) ok "Deploy SUKSES."; break ;;
      failure)
        warn "Deploy nyangkut (error transient GitHub Pages) — re-trigger otomatis..."
        git commit --allow-empty -m "retrigger deploy" >/dev/null 2>&1
        git push origin main >/dev/null 2>&1 || die "push retrigger gagal."
        attempt=$((attempt+1)) ;;
      timeout) die "Timeout menunggu deploy — cek tab Actions manual." ;;
    esac
  done
  [ $attempt -gt $max ] && die "Deploy gagal $max kali berturut — cek log di tab Actions."

  local url="https://${slug##*/}/"
  [[ "$slug" == */*.github.io ]] && url="https://${slug#*/}/"
  local code; code="$(curl -s -o /dev/null -w '%{http_code}' "$url")"
  ok "Live: $url  (HTTP $code)"

  # ingatkan kalau ada draft yang belum tayang
  local drafts; drafts="$(grep -rl '^draft: true' content/posts/ 2>/dev/null | sed 's#content/posts/##;s#/index.md##' | paste -sd', ' -)"
  if [ -n "$drafts" ]; then warn "Masih draft (belum tayang): $drafts  → blog.sh publish <slug>"; fi
  return 0
}

cmd_status(){
  local slug; slug="$(repo_slug)"
  local j; j="$(curl -s "https://api.github.com/repos/${slug}/actions/runs?per_page=1")"
  local st cc; st="$(echo "$j" | grep '"status"' | head -1 | cut -d'"' -f4)"; cc="$(echo "$j" | grep '"conclusion"' | head -1 | cut -d'"' -f4)"
  info "Deploy terakhir: status=$st conclusion=${cc:-<jalan>}"
  local url="https://${slug#*/}/"
  info "Live: $url → HTTP $(curl -s -o /dev/null -w '%{http_code}' "$url")"
}

usage(){ sed -n '2,11p' "$SELF" | sed 's/^# \{0,1\}//'; }

case "${1:-help}" in
  new)     shift; cmd_new "$@" ;;
  serve)   cmd_serve ;;
  build)   cmd_build ;;
  publish) shift; cmd_publish "$@" ;;
  deploy)  shift; cmd_deploy "$@" ;;
  status)  cmd_status ;;
  *)       usage ;;
esac
