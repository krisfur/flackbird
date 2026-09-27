#!/usr/bin/env bash
# Generates an original demo library for screenshots: abstract cover art,
# synthesized audio, and fictional names, so no third-party content ships in them.
set -euo pipefail

OUT="${1:-build/demo-library}"
command -v ffmpeg >/dev/null || { echo "ffmpeg is required: brew install ffmpeg" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Cover: a soft three-colour mesh gradient with one crisp motif on top.
cover() {
    local out="$1" c0="$2" c1="$3" c2="$4" motif="$5" seed="$6" mask
    case "$motif" in
        sun) mask='lt(hypot(X-500,Y-560),230)' ;;
        horizon) mask='gt(Y,640)' ;;
        rings) mask='lt(abs(mod(hypot(X-500,Y-500),90)-45),5)' ;;
        stripes) mask='lt(mod(X+Y,140),70)' ;;
        dots) mask='lt(hypot(mod(X,125)-62,mod(Y,125)-62),14)' ;;
        *) mask='0' ;;
    esac
    local blend="if($mask,0.25*%s(X,Y)+0.75*%s,%s(X,Y))"
    ffmpeg -hide_banner -loglevel error -y \
        -f lavfi -i "gradients=s=1000x1000:c0=$c0:c1=$c1:c2=$c2:nb_colors=3:type=radial:seed=$seed:speed=0" \
        -vf "format=rgb24,geq=r='$(printf "$blend" r 246 r)':g='$(printf "$blend" g 238 g)':b='$(printf "$blend" b 224 b)',gblur=sigma=1.2" \
        -frames:v 1 -q:v 3 "$out"
}

# Track: kick, bass, a bright pad, an arpeggio, 16th-note hats, and a little air, over
# four chords, so the visualiser has energy across the whole spectrum. random(n) keeps its
# state in variable n, so the noise uses slots clear of the st/ld ones.
track() {
    local out="$1" seconds="$2" rate="$3" bits="$4" bpm="$5" root="$6" coverfile="$7"
    shift 7
    local beat
    beat=$(awk "BEGIN { print 60 / $bpm }")
    local voice="st(1,mod(t,$beat));st(2,mod(floor(t/($beat*4)),4));\
st(3,$root*if(eq(ld(2),0),1,if(eq(ld(2),1),1.335,if(eq(ld(2),2),1.498,1.26))));\
0.7*sin(2*PI*(45+90*exp(-35*ld(1)))*ld(1))*exp(-8*ld(1))\
+0.18*sin(2*PI*ld(3)*t)\
+0.03*(sin(2*PI*ld(3)*4*t)+sin(4*PI*ld(3)*4*t)/2+sin(6*PI*ld(3)*4*t)/3+sin(8*PI*ld(3)*4*t)/4+sin(10*PI*ld(3)*4*t)/5)\
+0.03*(sin(2*PI*ld(3)*5.04*t)+sin(4*PI*ld(3)*5.04*t)/2+sin(6*PI*ld(3)*5.04*t)/3)\
+0.07*sin(2*PI*ld(3)*8*if(lt(mod(t,$beat),$beat/4),1,if(lt(mod(t,$beat),$beat/2),1.25,if(lt(mod(t,$beat),$beat*3/4),1.5,2)))*t)*exp(-6*mod(t,$beat/4))\
+0.35*(random(4)*2-1)*exp(-18*mod(t,$beat/4))\
+0.09*(random(5)*2-1)"
    ffmpeg -hide_banner -loglevel error -y \
        -f lavfi -i "aevalsrc=exprs='$voice|$voice':s=$rate:d=$seconds" \
        -i "$coverfile" \
        -map 0:a -map 1:v -af "volume=0.9,alimiter" -c:a flac -sample_fmt "$bits" \
        -c:v copy -disposition:v attached_pic -metadata:s:v comment="Cover (front)" \
        "$@" "$out"
}

# folder | album | artist | colours | motif | bpm | root Hz | tracks
ALBUMS=(
    "Evening|Blue Hour|Mira Solen|0x14213d 0x3a5a98 0xf2a65a|sun|96|55|Harbour Lights;Slow Signal;Blue Hour;Letters Home;Afterglow"
    "Evening|Quiet Harbour|Halcyon Drift|0x0b3c49 0x4f9d9a 0xe8dab2|horizon|84|49|Tidewater;Salt and Cedar;Lanterns;Quiet Harbour"
    "Focus|Paper Satellites|Lumen Tide|0x2b2d42 0x8d99ae 0xedf2f4|rings|110|61.7|Orbit;Paper Satellites;Low Earth;Relay;Static Bloom"
    "Focus|Glass Summer|Copper & Pine|0x6d597a 0xb56576 0xeaac8b|stripes|102|58.3|Glass Summer;Clearwater;Paper Kites;Sunroom"
    "Road Trip|Night Transit|Neon Orchard|0x10002b 0x7b2cbf 0xff9e00|dots|124|55|Night Transit;Exit Nine;Mile Markers;Tail Lights;Overpass"
    "Road Trip|Amber Fields|Avery Stone Quartet|0x3d2c1e 0xb07d48 0xf3d9a4|sun|118|65.4|Amber Fields;Gravel Road;Long Way Round;Dusk Drive"
    "Workout|Slow Bloom|Mira Solen|0x1b4332 0x52b788 0xd8f3dc|rings|128|55|Slow Bloom;Pulse;Second Wind;Uphill"
    "Workout|Low Tide Radio|Halcyon Drift|0x03045e 0x0096c7 0xcaf0f8|horizon|132|49|Low Tide Radio;Breakers;Undertow;Riptide"
)

echo "Generating demo library in $OUT"
seed=3
for entry in "${ALBUMS[@]}"; do
    IFS='|' read -r folder album artist colours motif bpm root titles <<<"$entry"
    read -r c0 c1 c2 <<<"$colours"
    seed=$((seed + 11))
    art="$WORK/$seed.jpg"
    cover "$art" "$c0" "$c1" "$c2" "$motif" "$seed"
    mkdir -p "$OUT/$folder"
    IFS=';' read -ra names <<<"$titles"
    for index in "${!names[@]}"; do
        number=$((index + 1))
        title="${names[$index]}"
        # The first track of Blue Hour plays in screenshots: full length and hi-res.
        if [[ "$album" == "Blue Hour" && $number == 1 ]]; then
            seconds=228 rate=48000 bits=s32
        else
            seconds=20 rate=44100 bits=s16
        fi
        track "$OUT/$folder/$artist - $title.flac" "$seconds" "$rate" "$bits" "$bpm" \
            "$(awk "BEGIN { print $root * (1 + 0.06 * $index) }")" "$art" \
            -metadata title="$title" -metadata artist="$artist" -metadata album="$album" \
            -metadata album_artist="$artist" -metadata track="$number/${#names[@]}" -metadata disc="1/1"
    done
    echo "  $folder / $album - $artist"
done
