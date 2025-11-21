#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# initial
help_text () {
    while IFS= read -r line; do
        printf "%s\n" "$line"
    done <<-EOF
	Usage:
	    ${0##*/} [ -o <filename> ] [ -r | -f | -n <no. of connections>] [ <m3u8_link> ]
	    ${0##*/} -h

	Options:
	    -h show helptext
	    -o filename (default : video)
	    -r select highest resolution automatically
	    -n set maximum number of connections (default : 36)
	    -f skip ffmpeg file conversion
	    -s subtitles url
	EOF
}

# default values
n=36
file="video"
tmpdir="${XDG_CACHE_HOME:-$HOME/.cache}/hls-temp"
jobdir="${XDG_CACHE_HOME:-$HOME/.cache}/hls-jobs"
failed="${XDG_CACHE_HOME:-$HOME/.cache}/hls-fail"

while getopts 'o:rfhn:s:' OPT; do
    case $OPT in
        o) file=$OPTARG ;;
        n) n=$OPTARG ;;
        f) skip_ffmpeg=1 ;;
        r) skip_res=1 ;;
        s) subs=$OPTARG ;;
        *) help_text; exit 0 ;;
    esac
done
shift $((OPTIND -1))

[ -z "$*" ] && printf "\033[1;34mEnter link >\033[0m " && read -r link || link=$*
cleanup_and_exit () {
    echo
    echo -e "\033[1;33m[YARIDA KESİLDİ] Partial merge yapılıyor...\033[0m"

    # indirilen ts'leri say
    count=$(ls "$TMPDIR"/*.ts 2>/dev/null | wc -l || echo 0)

    if [ "$count" -eq 0 ]; then
        echo -e "\033[1;31mHiç segment inmemiş, partial video oluşturulamadı.\033[0m"
    else
        echo -e "\033[1;32m$count adet segment bulundu, birleştiriliyor...\033[0m"

        # Birleştirme
        ls "$TMPDIR"/*.ts | sort | xargs cat | ffmpeg -y -loglevel error -stats -i - -c copy "${file}_partial.mp4"

        echo -e "\033[1;36mPartial video hazır: ${file}_partial.mp4\033[0m"
    fi

    # temp klasörünü sil
    rm -rf "$TMPDIR" "$jobdir" "$failed" || true

    exit 0
}

# YAKALANAN SİNYALLER
trap cleanup_and_exit INT HUP TERM


mkdir -p "$tmpdir"

printf "\033[2K\r\033[1;36mFetching resolutions.."
m3u8_data=$(curl -s "$link" | sed '/#EXT-X-I-FRAME-STREAM-INF/d')
res_list=$(printf "%s" "$m3u8_data" | sed -nE 's_.*RESOLUTION=.*x([^,]*).*_\1_p')
if [ -n "$res_list" ]; then
    highest_res=$(printf "%s" "$res_list" | sort -nr | head -1)
    if [ -z "${skip_res:-}" ]; then
        printf "\033[2K\r\033[1;33mRESOLUTIONS >>\n\033[0m%s\n\033[1;34mType ur preferred resolution (default: %s) > " "$res_list" "$highest_res"
        read -r sel_res || true
    else
        printf "\033[2K\r\033[1;36mSelecting highest resolution.."
    fi
    [ -z "${sel_res:-}" ] && sel_res=$highest_res
    url=$(printf "%s" "$m3u8_data" | sed -n "/x$sel_res/{n;p;}" | tr -d '\r')
    printf "%s" "$url" | grep -q "http" || relative_url=$(printf "%s" "$link" | sed 's|[^/]*$||')
    printf "\033[2K\r\033[1;36mFetching Metadata.."
    url="${relative_url}$url"
    resp="$(curl -s "$url")"
else
    url=$link
    resp=$m3u8_data
fi

key_uri="$(printf "%s" "$resp" | sed -nE 's/^#EXT-X-KEY.*URI="([^"]*)"/\1/p' || true)"
[ -z "$key_uri" ] || iv_uri="$(printf "%s" "$resp" | sed -nE 's/^#EXT-X-IV.*URI="([^"]*)"/\1/p' || true)"
data="$(printf "%s" "$resp" | sed '/#/d')"
printf "%s" "$data" | grep -q "http" && relative_url='' || relative_url=$(printf "%s" "$url" | sed 's|[^/]*$||')
range=$(printf "%s\n" "$data" | wc -l)

if [ -n "$key_uri" ]; then
    key=$(curl -s "$key_uri" | od -A n -t x1 | tr -d ' |\n')
    [ -z "${iv_uri:-}" ] && iv=$(openssl rand -hex 16) || iv=$(curl -s "$iv_uri" | od -A n -t x1 | tr -d ' |\n')
fi

printf "\033[2K\r\033[1;35mpieces : %s\n\033[1;33mPreparing downloads.." "$range"

# Prepare segment index + full URL list
segments_file="$tmpdir/segments.txt"
: > "$segments_file"
idx=1
while IFS= read -r seg_line; do
    seg=$(printf "%s" "$seg_line" | tr -d '\r')
    [ -z "$seg" ] && { idx=$((idx+1)); continue; }
    if printf "%s" "$seg" | grep -q "^http"; then
        full="$seg"
    else
        full="${relative_url}${seg}"
    fi
    printf "%s %s\n" "$idx" "$full" >> "$segments_file"
    idx=$((idx+1))
done <<-EOF
$(printf "%s\n" "$data")
EOF

# files to record progress
DONEFILE="$tmpdir/done.list"
FAILEDFILE="$tmpdir/failed.list"
: > "$DONEFILE"
: > "$FAILEDFILE"

# Export env for xargs children
export TMPDIR="$tmpdir"
export DONEFILE
export FAILEDFILE

# If aria2c available, use it (it handles parallelism itself)
if command -v aria2c >/dev/null 2>&1; then
    printf "\033[2K\r\033[1;33mUsing aria2c for fast parallel download..\n"
    # build aria2 input file: url \n\tout=NNNN.ts
    aria_in="$tmpdir/aria.input"
    : > "$aria_in"
    awk -v rel="$relative_url" '{printf "%s\n\tout=%05d.ts\n", $2, $1}' "$segments_file" > "$aria_in"
    aria2c --no-conf=true --enable-rpc=false -x16 -s16 -j "$n" -k1M -d "$TMPDIR" -i "$aria_in" --download-result=hide --summary-interval=0
    # mark all as done (simple approximation)
    awk '{print $1}' "$segments_file" >> "$DONEFILE"
else
    # --------- Colab-safe parallel downloader using xargs -P ----------
    # Start a small monitor in background to show live progress (works without job control)
    (
        while :; do
            cnt=$(wc -l < "$DONEFILE" 2>/dev/null || echo 0)
            printf "\r\033[2K\033[1;32m ✓ %s / %s done" "$cnt" "$range"
            if [ "$cnt" -ge "$range" ]; then
                printf "\n"
                break
            fi
            sleep 0.25
        done
    ) &

    # Run parallel downloads: each worker appends its index to DONEFILE or FAILEDFILE
    # Use xargs -n2 -P to read "index url" pairs from segments_file
    cat "$segments_file" | xargs -n2 -P "$n" sh -c '
        idx="$1"; url="$2"
        out="$TMPDIR/$(printf "%05d" "$idx").ts"
        # -f makes curl return non-zero on HTTP error
        if curl --max-time 30 -s -f "$url" -o "$out"; then
            printf "%s\n" "$idx" >> "$DONEFILE"
        else
            printf "%s\n" "$idx" >> "$FAILEDFILE"
        fi
    ' sh
fi

# if failed pieces exist, retry once (serial retry to avoid complexity)
if [ -s "$FAILEDFILE" ]; then
    printf "\033[2K\r\033[1;33mRetrying %s failed pieces..\n" "$(wc -l < "$FAILEDFILE")"
    while IFS= read -r idx; do
        url=$(awk -v i="$idx" '$1==i{print $2}' "$segments_file")
        out="$TMPDIR/$(printf "%05d" "$idx").ts"
        if curl --max-time 30 -s -f "$url" -o "$out"; then
            printf "%s\n" "$idx" >> "$DONEFILE"
        else
            printf "%s\n" "$idx" >> "$FAILEDFILE.retry"
        fi
    done < "$FAILEDFILE"
fi

printf "\033[2K\r\033[1;36mConcatenating pieces..\n"
if [ -n "${key_uri:-}" ]; then
    # decrypt and concat
    : > "$file.ts"
    for piece in "$TMPDIR"/*.ts; do
        openssl aes-128-cbc -d -K "$key" -iv "$iv" -nopad >> "$file.ts" < "$piece"
    done
    ffmpeg -y -i "$file.ts" -loglevel error -stats -c copy "$file.mp4"
else
    # pipe to ffmpeg to avoid huge intermediate file
    ls "$TMPDIR"/*.ts | sort | xargs cat | ffmpeg -y -loglevel error -stats -i - -c copy "$file.mp4"
fi

# subtitles
[ -z "${subs:-}" ] || curl -s "$subs" -o "$file.srt" &

# cleanup
rm -rf "$TMPDIR" "$jobdir" "$failed" || true
[ -f "$file.ts" ] && rm -f "$file.ts"
printf "\033[2K\r\033[1;36m Done!!\n"
