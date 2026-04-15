import requests
import zipfile
import io
import pandas as pd
import sqlite3

url = "https://rss.epublibre.org/csv"
response = requests.get(url)
response.raise_for_status()


with zipfile.ZipFile(io.BytesIO(response.content)) as z:
    with z.open("datos.csv") as f:
        df = pd.read_csv(f)


conn = sqlite3.connect("datos.db")
df.to_sql("mi_tabla", conn, if_exists="replace", index=False)
conn.close()

print("Done!")