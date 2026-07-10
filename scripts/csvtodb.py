import sys
import requests
import zipfile
import io
import pandas as pd
import sqlite3

url = "https://rss.epublibre.org/csv"
print(f"Downloading from {url}...")
try:
    response = requests.get(url, timeout=120)
    response.raise_for_status()
except requests.RequestException as e:
    print(f"ERROR: Failed to download CSV: {e}", file=sys.stderr)
    sys.exit(1)

try:
    with zipfile.ZipFile(io.BytesIO(response.content)) as z:
        with z.open("epublibre.csv") as f:
            df = pd.read_csv(f)
except Exception as e:
    print(f"ERROR: Failed to parse CSV: {e}", file=sys.stderr)
    sys.exit(1)

COLUMNS = {
    "Título": "title",
    "Autor": "author",
    "Año publicación": "year",
    "Enlace(s)": "magnet",
}

missing = [c for c in COLUMNS if c not in df.columns]
if missing:
    print(f"ERROR: Missing columns in CSV: {missing}", file=sys.stderr)
    print(f"Available columns: {list(df.columns)}", file=sys.stderr)
    sys.exit(1)

df = df[list(COLUMNS.keys())].rename(columns=COLUMNS)

# Only prepend magnet prefix if not already present
df["magnet"] = df["magnet"].apply(
    lambda h: h if str(h).startswith("magnet:") else "magnet:?xt=urn:btih:" + str(h)
)

conn = sqlite3.connect("datos.db")
df.to_sql("books", conn, if_exists="replace", index=False)
conn.close()

print(f"Done! {len(df)} books imported.")
