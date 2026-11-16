#!/bin/bash

# Directory containing the ARB files
l10n_dir="./lib/l10n"
# Target directory for the locale_config.xml file
xml_dir="./android/app/src/main/res/xml"

# Create the target directory if it does not exist
mkdir -p "$xml_dir"

# Output file name
xml_file="$xml_dir/locale_config.xml"

rm -rf "$xml_file"

# XML Header
echo '<?xml version="1.0" encoding="utf-8"?>' > "$xml_file"
echo '<locale-config xmlns:android="http://schemas.android.com/apk/res/android">' >> "$xml_file"

# Search for ARB files and extract language codes
for file in "$l10n_dir"/intl_*.arb; do
  # Extraire le tag complet : garder les sous-tags région/script (pt-BR,
  # zh-Hant…). L'ancien cut -d'_' -f2 écrêtait tout après la langue :
  # pt×3, zh×2, yue nu — Android livrait la première occurrence et les
  # variantes restaient introuvables (audit ultracode #18).
  language_code=$(basename "$file" .arb | sed 's/^intl_//' | tr '_' '-')
  # Write language code to the XML file
  echo "    <locale android:name=\"$language_code\"/>" >> "$xml_file"
done

# XML Footer
echo '</locale-config>' >> "$xml_file"

echo "locale_config.xml file has been successfully created in the $xml_dir directory."
