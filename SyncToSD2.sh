#!/bin/bash

#Sync files with SD card. Copy over new files, delete old files
######################################################
# Customize these variables before using this script
######################################################
# This is the full path to the local folder you want to
# sync with your SD card. Make sure to keep a trailing
# slash at the end
LPATH="/LOCAL_DIRECTORY/G_Code"

# This is path on the FlashAir card
RPATH="/REMOTE_DIRECTORY/G_Code"

# This is the IP address assigned to the WiFi card.
# Works with hostname also if you have proper DNS
# configured
FLASHAIR="IPADDRESS"
######################################################

DEBUG=0
GREP=$(which grep)
AWK=$(which awk)
CUT=$(which cut)
SED=$(which sed)
WC=$(which wc)
LS=$(which ls)
CURL=$(which curl)
SORT=$(which sort)
PCMD=$(which ping)
PRINTF=$(which printf)
STAT=$(which stat)
PING="${PCMD} -q -c3 -W 10 "
DIR=$(pwd)
TMP_FILE_NAME="SyncToSD2.temp"
TMP_FILE_HEADER="SyncToSD2.header"
TMP_FILE="${DIR}/${TMP_FILE_NAME}"
TMP_HEADER="${DIR}/${TMP_FILE_HEADER}"

function date2dos(){
        year=$(date +%Y)
        year=$(($year-1980))
        year=$((year << 9))
        month=$(date +%-m)
        month=$((month << 5))
        day=$(date +%-d)
        hour=$(date +%-H)
        hour=$((hour << 11))
        minute=$(date +%-M)
        minute=$((minute << 5))
        second=$(date +%-S)
        second=$(($second/2))
        d=$(($year + $month + $day))
        d=$((d << 16))
        t=$(($hour + $minute + $second))
        ${PRINTF} '0x%x' $(($d+$t)) 
}

#Check if printer is online
${PING} ${FLASHAIR} > /dev/null
if [ $? -ne 0 ]; then
        #echo "Printer Offline"
        osascript -e "display notification \"3D Printer offline\" with title \"Cannot upload models\""
        exit 0
fi

#Retrieve filelist from local filesystem
GCODE=$(for file in ${LPATH}/*.gcode; do echo "${file##*/}"; done)

#Retrieve flashair filelist for directory from flashair card & loop thru flashair filelist
${CURL} --silent "http://${FLASHAIR}/command.cgi?op=100&DIR=${RPATH}" | tail -n +2 > "${TMP_FILE}"
SDCOUNT=0
while read LINE;
do
        CARD_SUBITEM_NAME=$(echo "${LINE}" | cut -d',' -f2)
        CARD_SUBITEM_TYPE=$(echo "${LINE}" | cut -d',' -f4)
        # if current subitem is a file
        if [ ${CARD_SUBITEM_TYPE} -ge 32 ] &&  [ ${CARD_SUBITEM_NAME: -6} == ".gcode" ]; then
                REMOTELIST="${REMOTELIST}\n${CARD_SUBITEM_NAME}"
                SDCOUNT=$[$SDCOUNT +1]
        fi
done < "${TMP_FILE}"

#Compare file differences
ADDLIST=$(comm -13 <(echo -e "${REMOTELIST}" | ${SORT}) <(echo "${GCODE}" | ${SED} -e 's/[[:space:]]*$//' | ${SORT}))
DELLIST=$(comm -23 <(echo -e "${REMOTELIST}" | ${SORT}) <(echo "${GCODE}" | ${SED} -e 's/[[:space:]]*$//' | ${SORT}))
SAMELIST=$(comm -12 <(echo -e "${REMOTELIST}" | ${SORT}) <(echo "${GCODE}" | ${SED} -e 's/[[:space:]]*$//'| ${SORT}))

ADDCOUNT=$(echo $ADDLIST | ${GREP} .gcode | ${WC} -l)
DELCOUNT=$(echo $DELLIST | ${GREP} .gcode | ${WC} -l)
SAMECOUNT=$(echo $SAMELIST | ${GREP} .gcode | ${WC} -l)
LOCOUNT=$(echo "${GCODE}"| ${WC} -l | ${AWK} '{print $1}')

if [ $DEBUG == 1 ]; then
        echo "SDCOUNT: '${SDCOUNT}'"
        echo "LOCOUNT: '${LOCOUNT}'"
        echo "DELLIST: '${DELLIST}'"
        echo "ADDLIST: '${ADDLIST}'"
        echo "SAMELIST: '${SAMELIST}'"
        echo "ADDCOUNT: '${ADDCOUNT}'"
        echo "DELCOUNT: '${DELCOUNT}'"
        echo "SAMECOUNT: '${SAMECOUNT}'"
        exit 0
fi

if [ $ADDCOUNT == 0 ] && [ $DELCOUNT == 0 ] && [ $SAMECOUNT == 0 ]; then
        #Nothing more to do. Exit!
        #echo Nothing to do
        osascript -e "display notification \"Nothing to do\" with title \"SD Card Sync\""
        exit 0
fi

if [ $LOCOUNT == 0 ] && [ $SDCOUNT != 0 ]; then
        #Local folder is empty - no files to be copied and all remote to be deleted
        osascript -e "display notification \"Clearing SD card\" with title \"SD Card Sync\""
        ${SDRM} "*.gcode"
        exit 0
fi

OIFS="$IFS"
IFS=$'\n'

if [ $DELCOUNT -gt 0 ]; then
        #Delete files on SD card that are not available locally
        for FOO in $DELLIST ; do
		FOO_NS="$(echo -e "${FOO}" | ${SED} -e 's/[[:space:]]*$//')"
                ITEM="${RPATH}/${FOO_NS}"
                osascript -e "display notification \"Deleting ${FOO_NS}\" with title \"SD Card Sync\""
                #Send deletion command    
                ${CURL} --silent --output /dev/null --dump-header "${TMP_HEADER}" "http://${FLASHAIR}/upload.cgi?DEL=${ITEM}"
        done
fi

if [ $ADDCOUNT -gt 0 ] ||  [ $SAMECOUNT -gt 0 ]; then
        #Set upload directory
        ${CURL} --silent --output "${TMP_FILE}" --dump-header "${TMP_HEADER}" "http://${FLASHAIR}/upload.cgi?UPDIR=${RPATH}"
        OPERATION_OK=$(grep "SUCCESS" "${TMP_FILE}")
        [ "${OPERATION_OK}" == "" ] && exit 1
        
        #Keep the host from writing during upload
        ${CURL} --silent --output "${TMP_FILE}" --dump-header "${TMP_HEADER}" "http://${FLASHAIR}/upload.cgi?WRITEPROTECT=ON"
        OPERATION_OK=$(grep "SUCCESS" "${TMP_FILE}")
        [ "${OPERATION_OK}" == "" ] && exit 1

        #Set time of upload
        FTIME=$(date2dos)
        ${CURL}  --silent --output "${TMP_FILE}" --dump-header "${TMP_HEADER}" "http://${FLASHAIR}/upload.cgi?FTIME=${FTIME}"
        OPERATION_OK=$(grep "SUCCESS" "${TMP_FILE}")
        [ "${OPERATION_OK}" == "" ] && exit 1

        #Copy local files to remote
        if [ $ADDCOUNT -gt 0 ]; then
                for FOO in $ADDLIST ; do
        		FOO_NS="$(echo -e "${FOO}" | ${SED} -e 's/[[:space:]]*$//')"
                        ITEM="${LPATH}/${FOO_NS}"
                        osascript -e "display notification \"Adding ${FOO_NS}\" with title \"SD Card Sync\""
                        ${CURL} --silent --output /dev/null --dump-header "${TMP_HEADER}" -i -X POST -H "Content-Type: multipart/form-data" -F "data=@${ITEM}" "http://${FLASHAIR}/upload.cgi"
                done
        fi

        #Update local files to remote if less than OLDTIME
        if [ $SAMECOUNT -gt 0 ]; then
                OLDTIME=60
                CURTIME=$(date +%s)
                #Determine if existing files need to be re-uploaded
                for FOO in $SAMELIST ; do
                        FOO_NS="$(echo -e "${FOO}" | ${SED} -e 's/[[:space:]]*$//')"
                        ITEM="${LPATH}/${FOO_NS}"
                        FILETIME=$(${STAT} -t %s -f %m ${ITEM})
                        TIMEDIFF=$(expr $CURTIME - $FILETIME)
                        if [ $TIMEDIFF -lt $OLDTIME ]; then
                                osascript -e "display notification \"Updating ${FOO}\" with title \"SD Card Sync\""
                                #Upload
                                ${CURL} --silent --output /dev/null --dump-header "${TMP_HEADER}" -i -X POST -H "Content-Type: multipart/form-data" -F "data=@${ITEM}" "http://${FLASHAIR}/upload.cgi"
                        fi 
                done
        fi

        ${CURL} --silent --output "${TMP_FILE}" --dump-header "${TMP_HEADER}" "http://${FLASHAIR}/upload.cgi?WRITEPROTECT=OFF"
        OPERATION_OK=$(grep "SUCCESS" "${TMP_FILE}")
        [ "${OPERATION_OK}" == "" ] && exit 1
fi

IFS="$OIFS" 

[ -f "${TMP_FILE}" ] && rm -f "${TMP_FILE}"
[ -f "${TMP_HEADER}" ] && rm -f "${TMP_HEADER}"

osascript -e "display notification \"Done!\" with title \"SD Card Sync\""
