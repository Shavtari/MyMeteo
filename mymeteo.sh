#!/bin/bash


OPTIND=1

#CONFIG BEGIN

CONFIG="$HOME/.mymeteorc"

BLACK=$(tput setaf 0)
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
LIME_YELLOW=$(tput setaf 190)
POWDER_BLUE=$(tput setaf 153)
BLUE=$(tput setaf 4)
MAGENTA=$(tput setaf 5)
CYAN=$(tput setaf 6)
WHITE=$(tput setaf 7)
BRIGHT=$(tput bold)
NORMAL=$(tput sgr0)
BLINK=$(tput blink)
REVERSE=$(tput smso)
UNDERLINE=$(tput smul)

if [ -f "$CONFIG" ]; then
    source "$CONFIG"
else
	cat > "$CONFIG" << EOF
#Available colors:
#BLACK, RED, GREEN, YELLOW, LIME_YELLOW, POWDER_BLUE, BLUE, MAGENTA, CYAN, WHITE

#Available emphases:
#BRIGHT, BLINK, REVERSE, UNDERLINE

#Default:
#NORMAL

NICE_COLOR="\$MAGENTA"
DEFAULT_COLOR="\$NORMAL"
EMPHASIS="\$UNDERLINE"
verbose=false
CACHE_PATH="$HOME/.cache/mymeteo/stations_cache.json"
USER_AGENT="BashMyMeteo/1.0"
EOF
	source "$CONFIG"
fi

#CONFIG END

Help()
{
	echo "A script to get weather data from the closest Polish weather station to given city."
	echo "Script made by Paweł Wieczorek."
	echo 
	echo "Usage:"
	echo "  $0 [OPTIONS] [CITY] "
	echo
	echo "Options:"
	echo -e "  -h\tPrint this help and exit."
	echo -e "  -v\tVerbose mode."
	echo
	echo "Example:"
	echo "  $0 \"Kórnik\""
	echo
	echo "RC File saved at: $CONFIG"
	echo "Cache saved at: $CACHE_PATH"
}

Log() {
    if [ "$verbose" = true ]; then
        echo "$1"
    fi
}


while getopts "hv" option; do
	case $option in
		h)
		Help
		exit 0
		;;
		v)
		verbose=true
		;;
		\?)
		echo "$0 -h"
		echo "for more info."
		exit 2
		;;
	esac
done

shift $((OPTIND-1))

#####################################
#			MAIN SCRIPT				#
#####################################

#haversine function
calculate_distance() {
    local lat1=$1
    local lon1=$2
    local lat2=$3
    local lon2=$4

    awk -v lat1="$lat1" -v lon1="$lon1" -v lat2="$lat2" -v lon2="$lon2" '
    BEGIN {
        R = 6372.8 # Earth radius in km
        PI = atan2(1,1)*4
        RAD = PI / 180

        dphi = (lat2 - lat1) * RAD
        dlambda = (lon2 - lon1) * RAD
        phi1 = lat1 * RAD
        phi2 = lat2 * RAD

        a = (sin(dphi/2) ^ 2) + cos(phi1) * cos(phi2) * (sin(dlambda/2) ^ 2)
        
        if (a > 1) a = 1
        c = 2 * atan2(sqrt(a), sqrt(1-a))
        
        printf "%.4f", R * c
    }'
}

#fixes problem with polish characters
#converts input string into a UTF-8 representation writen in hex
url_encode() {
    printf "$1" | od -An -t x1 | tr -d '\n' | tr -s ' ' | sed 's/ /%/g'
}


city=$1

if [ -z "$city" ]; then
    echo "City name cannot be empty."
	echo "Use -h for more info"
    exit 1
fi

NOMINATIM_URL="https://nominatim.openstreetmap.org/search"
NOMINATIM_QUERY=$"$NOMINATIM_URL?country=poland&format=json&limit=1&city="
IMGW_URL="https://danepubliczne.imgw.pl/api/data/synop/"
IMGW_ID_SEARCH="https://danepubliczne.imgw.pl/api/data/synop/id/"


check_cache() {
    if [ -f "$CACHE_PATH" ]; then
        Log "Cache found at $CACHE_PATH."
		Log "Skipping download."
        return
    fi
	
	Log "Cache not found"
	Log "Downloading data"
	
	mkdir -p "$(dirname "$CACHE_PATH")"
	
	station_data=$(curl -s "$IMGW_URL" | jq -r '.[] | "\(.id_stacji)\t\(.stacja)"')

	count=0
	total=$(echo "$station_data" | wc -l)

	temp_file=".temp_stations.json"
    > "$temp_file"
	
	while IFS=$'\t' read -r station; 
	do
		read -r station_id station_name <<< "$station"
		station_name=$(echo "$station_name" | tr -d '\r' | xargs)
		
		clean_station=$(url_encode "$station_name")
		json_resp=$(curl -s -G -A "$USER_AGENT" "$NOMINATIM_QUERY$clean_station")

		((count++))
		echo -en "\033[KDownloading locations of stations ($count/$total): $station_name\r"
		if [ "$(echo "$json_resp" | jq 'length')" -gt 0 ]; then
			 echo "$json_resp" | jq -c --arg name "$station_name" --arg id "$station_id" \
             '.[0] | {station_id: $id, name: $name, lat: .lat, lon: .lon}' >> "$temp_file"
        fi
		sleep 1

	done <<< "$station_data"
	
    jq -s '.' "$temp_file" > "$CACHE_PATH"
    rm "$temp_file"
    Log "Cache saved to $CACHE_PATH"
}

Log "Searching for city $city"

clean_city=$(url_encode "$city")

geo_api=$(curl -s -G -A "$USER_AGENT" "$NOMINATIM_QUERY$clean_city")
	
sleep 1

if [ "$(echo "$geo_api" | jq 'length')" -eq 0 ]; then
    echo "City not found"
    exit 1
fi

city_lat="$(echo "$geo_api" | jq -r '.[0].lat')"
city_lon="$(echo "$geo_api" | jq -r '.[0].lon')"
city_name="$(echo "$geo_api" | jq -r '.[0].name')"
Log "Found: $city_name ($city_lat, $city_lon)"


check_cache

Log "Calculating distances"

closest_station=""
closest_station_lat=""
closest_station_lon=""
closest_station_id=""
min_distance=99999

while read -r lat lon name id; do
    dist=$(calculate_distance "$city_lat" "$city_lon" "$lat" "$lon")
    
    is_closer=$(awk -v d="$dist" -v min="$min_distance" 'BEGIN {print (d < min ? 1 : 0)}')
    
    if [ "$is_closer" -eq 1 ]; then
        min_distance=$dist
        closest_station=$name
		closest_station_lat=$lat
		closest_station_lon=$lon
		closest_station_id=$id
    fi
done < <(jq -r '.[] | "\(.lat) \(.lon) \(.name) \(.station_id)"' "$CACHE_PATH")


Log "Closest Station: $closest_station, $min_distance from $city_name"


search_url=$(echo "$IMGW_ID_SEARCH$closest_station_id" | tr -d '\r' | xargs)

result=$(curl -s "$search_url")

print_weather() {
    local json_data="$1"

    IFS=$'\t' read -r id city date hour temp wind_s wind_d humid rain press <<< "$(echo "$json_data" | jq -r '[
        .id_stacji, 
        .stacja, 
        .data_pomiaru, 
        .godzina_pomiaru, 
        .temperatura, 
        .predkosc_wiatru, 
        .kierunek_wiatru, 
        .wilgotnosc_wzgledna, 
        .suma_opadu, 
        .cisnienie
    ] | @tsv')"

    printf "${NICE_COLOR}${EMPHASIS}\n%s [%s] / %s %02d:00\n\n" "$city" "$id" "$date" "$hour"
    printf "${DEFAULT_COLOR}%-18s\t%6s %-1s\n"  		"Temperatura:"      "$temp"		"°C"
    printf "%-18s\t%6s %-1s\n" 			"Prędkość wiatru:"  "$wind_s"	"m/s"
    printf "%-18s\t%6s %-1s\n"   		"Kierunek wiatru:"  "$wind_d"	"°"
    printf "%-18s\t%6s %-1s\n"  		"Wilgotność wzgl.:" "$humid"	"%"
    printf "%-18s\t%6s %-1s\n"  		"Suma opadu:"       "$rain"		"mm"
    printf "%-18s\t%6s %-1s\n" 			"Ciśnienie:"        "$press"	"hPa"
    echo
}

print_weather "$result"
