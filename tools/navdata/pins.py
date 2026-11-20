"""Pinned public sources for the national radio simulation.

Bulk files are downloaded into the build. They are not committed.
"""

OURAIRPORTS_AIRPORTS = "https://davidmegginson.github.io/ourairports-data/airports.csv"
OURAIRPORTS_RUNWAYS = "https://davidmegginson.github.io/ourairports-data/runways.csv"
OURAIRPORTS_FREQUENCIES = (
    "https://davidmegginson.github.io/ourairports-data/airport-frequencies.csv"
)

NASR_CYCLE = "2026-10-29"
NASR_APT_CSV = "https://nfdc.faa.gov/webContent/28DaySub/extra/29_Oct_2026_APT_CSV.zip"

T100_YEAR = 2025
T100_MONTH = 1
T100_FORM = (
    "https://www.transtats.bts.gov/DL_SelectFields.aspx"
    "?gnoyr_VQ=FIM&QO_fu146_anzr=Nv4%20Pn44vr45"
)

TOP_PAIRS = 8
ENROUTE_MHZ = 135.0
BAND_LOW = 118.0
BAND_HIGH = 136.975
