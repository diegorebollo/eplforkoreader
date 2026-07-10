import requests
import zipfile
import io
import pandas as pd 
import sqlite3

url = "https://rss.epublibre.org/csv"
response = requests.get(url)
response.raise_for_status()

with zipfile.ZipFile(io.BytesIO(response.content)) as z:
    with z.open("epublibre.csv") as f:
        df = pd.read_csv(f)

COLUMNS = {
    "Título": "title",
    "Autor": "author",
    "Año publicación": "year",
    "Enlace(s)": "magnet",
}

df = df[list(COLUMNS.keys())].rename(columns=COLUMNS)
df["magnet"] = "magnet:?xt=urn:btih:" + df["magnet"]

conn = sqlite3.connect("datos.db")
df.to_sql("books", conn, if_exists="replace", index=False)
conn.close()

print("Done!")