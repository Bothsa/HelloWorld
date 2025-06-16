#!/bin/bash

# === CONFIG ===
JFROG_URL="https://trialuql2s4.jfrog.io/artifactory"
REPO="esb-cloudhub-snapshot-local"
ROOT_PATH="com/lla/account-btw-biz"
USERNAME="shrimadhu119@gmail.com"
API_KEY="cmVmdGtuOjAxOjE3ODEyNTM5MzE6NDN6cEdMcWlSZ0dhc0I4aTI5aXRjOXpUYWFr"
KEEP_JARS=2        # Keep latest 2 JARs per version folder
KEEP_FOLDERS=3     # Keep latest 3 version folders

echo "⏳ Scanning all JARs under: $ROOT_PATH in $REPO..."

# Step 1: Get all entries recursively
json=$(curl --ssl-no-revoke -s -u "$USERNAME:$API_KEY" \
  "$JFROG_URL/api/storage/$REPO/$ROOT_PATH?list&deep=1")

# Step 2: Parse .jar file paths
jar_paths=($(echo "$json" | grep -oP '"uri"\s*:\s*"\K[^"]+' | grep '\.jar$'))

if [ ${#jar_paths[@]} -eq 0 ]; then
  echo "❌ No JAR files found under $ROOT_PATH"
  exit 1
fi

# Step 3: Group JARs by version directory
declare -A jars_by_version
declare -A version_lastmod

for path in "${jar_paths[@]}"; do
  relative_path="${path#/}"
  version_folder=$(echo "$relative_path" | cut -d'/' -f1)
  jars_by_version["$version_folder"]+="${relative_path}"$'\n'

  # Get last modified time for version folder (only once)
  if [ -z "${version_lastmod[$version_folder]}" ]; then
    stats_json=$(curl --ssl-no-revoke -s -u "$USERNAME:$API_KEY" \
      "$JFROG_URL/api/storage/$REPO/$ROOT_PATH/$version_folder")
    modified=$(echo "$stats_json" | grep -oP '"lastModified" : "\K[^"]+')
    if [ -n "$modified" ]; then
      epoch=$(date -d "$modified" +%s)
      version_lastmod["$version_folder"]=$epoch
    fi
  fi
done

# Step 4: JAR cleanup inside each version folder
for version in "${!jars_by_version[@]}"; do
  echo -e "\n📦 Cleaning version folder: $version"
  IFS=$'\n' read -rd '' -a jars <<< "$(echo "${jars_by_version[$version]}")"
  jar_with_time=()

  for jar in "${jars[@]}"; do
    stats_json=$(curl --ssl-no-revoke -s -u "$USERNAME:$API_KEY" \
      "$JFROG_URL/api/storage/$REPO/$ROOT_PATH/$jar")
    modified=$(echo "$stats_json" | grep -oP '"lastModified" : "\K[^"]+')
    if [ -n "$modified" ]; then
      epoch=$(date -d "$modified" +%s)
      jar_with_time+=("$epoch|$jar")
    fi
  done

  IFS=$'\n' sorted_jars=($(printf "%s\n" "${jar_with_time[@]}" | sort -r))
  total=${#sorted_jars[@]}
  if [ $total -le $KEEP_JARS ]; then
    echo "✅ Only $total artifacts found. Nothing to delete."
    continue
  fi

  echo "🔐 Total artifacts: $total. Keeping latest $KEEP_JARS, deleting $((total - KEEP_JARS)) old..."
  for ((i=KEEP_JARS; i<total; i++)); do
    jar_path=$(echo "${sorted_jars[$i]}" | cut -d'|' -f2)
    delete_url="$JFROG_URL/$REPO/$ROOT_PATH/$jar_path"
    echo "🗑️  Deleting: $delete_url"
    curl --ssl-no-revoke -s -u "$USERNAME:$API_KEY" -X DELETE "$delete_url"
  done
done

# Step 5: Version folder cleanup
echo -e "\n📂 Evaluating version folders to retain only the latest $KEEP_FOLDERS..."

version_time_list=()
for version in "${!version_lastmod[@]}"; do
  version_time_list+=("${version_lastmod[$version]}|$version")
done

IFS=$'\n' sorted_versions=($(printf "%s\n" "${version_time_list[@]}" | sort -r))
total_versions=${#sorted_versions[@]}

if [ $total_versions -le $KEEP_FOLDERS ]; then
  echo "✅ Only $total_versions version folders found. Nothing to delete."
else
  echo "🗑️  Deleting $((total_versions - KEEP_FOLDERS)) old version folders..."
  for ((i=KEEP_FOLDERS; i<total_versions; i++)); do
    folder=$(echo "${sorted_versions[$i]}" | cut -d'|' -f2)
    delete_url="$JFROG_URL/$REPO/$ROOT_PATH/$folder"
    echo "🗑️  Deleting version folder: $delete_url"
    curl --ssl-no-revoke -s -u "$USERNAME:$API_KEY" -X DELETE "$delete_url"
  done
fi

echo -e "\n✅ Cleanup of artifacts and folders completed based on last modified timestamps!"
