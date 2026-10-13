"""Trial operations dashboard.

A small Shiny for Python app used to demonstrate a secure AWS build.
All data is synthetic and generated at start-up. No real patient data.

Behind the AWS Application Load Balancer, every request carries
x-amzn-oidc-data: a JWT the load balancer signs after the user has
signed in with Microsoft Entra ID. The app verifies that signature
before trusting the user's name, then writes an audit line for each
action (who, what, when) to stdout, which Podman writes to a log file
that the CloudWatch agent ships off the server.
"""

import json
import logging
import os
import sys
from datetime import datetime, timezone

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402
from shiny import App, reactive, render, ui  # noqa: E402
from starlette.applications import Starlette  # noqa: E402
from starlette.responses import PlainTextResponse  # noqa: E402
from starlette.routing import Mount, Route  # noqa: E402

from identity import identity_from_headers  # noqa: E402

APP_VERSION = os.environ.get("APP_VERSION", "dev")
# No verified login, no data. Only an explicit REQUIRE_LOGIN=false (local testing) turns this off.
REQUIRE_LOGIN = os.environ.get("REQUIRE_LOGIN", "true").lower() != "false"

# ---------- audit logging: one JSON line per event ----------
audit_log = logging.getLogger("audit")
audit_log.setLevel(logging.INFO)
_handler = logging.StreamHandler(sys.stdout)
_handler.setFormatter(logging.Formatter("%(message)s"))
audit_log.addHandler(_handler)
audit_log.propagate = False


def audit(user: str, action: str, **detail) -> None:
    audit_log.info(
        json.dumps(
            {
                "ts": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "type": "audit",
                "user": user,
                "action": action,
                "detail": detail,
                "app_version": APP_VERSION,
            }
        )
    )


# ---------- synthetic, pseudonymised trial data ----------
def make_data(seed: int = 42) -> pd.DataFrame:
    rng = np.random.default_rng(seed)
    sites = ["UK-01 London", "UK-02 Manchester", "UK-03 Leeds", "UK-04 Glasgow"]
    n = 240
    start = np.datetime64("2026-01-05")
    df = pd.DataFrame(
        {
            "subject_id": [f"S-{i:04d}" for i in range(1, n + 1)],
            "site": rng.choice(sites, size=n, p=[0.35, 0.25, 0.22, 0.18]),
            "arm": rng.choice(["A", "B"], size=n),
            "enrolled": start + rng.integers(0, 270, size=n).astype("timedelta64[D]"),
            "visits_completed": rng.integers(1, 9, size=n),
            "adverse_events": rng.poisson(0.4, size=n),
        }
    )
    df["enrolled"] = pd.to_datetime(df["enrolled"])
    return df.sort_values("enrolled").reset_index(drop=True)


DATA = make_data()
SITES = ["All sites"] + sorted(DATA["site"].unique().tolist())

# ---------- UI ----------
app_ui = ui.page_sidebar(
    ui.sidebar(
        ui.input_select("site", "Site", choices=SITES),
        ui.input_radio_buttons("arm", "Arm", choices=["Both", "A", "B"], inline=True),
        ui.hr(),
        ui.output_ui("signed_in"),
        ui.p(
            ui.tags.small(f"Version {APP_VERSION}. Synthetic data for demonstration only."),
        ),
        width=280,
    ),
    ui.layout_columns(
        ui.value_box("Subjects enrolled", ui.output_text("kpi_enrolled")),
        ui.value_box("Mean visits completed", ui.output_text("kpi_visits")),
        ui.value_box("Adverse events", ui.output_text("kpi_ae")),
        fill=False,
    ),
    ui.card(ui.card_header("Enrolment by month"), ui.output_plot("enrolment", height="300px")),
    ui.card(ui.card_header("Subjects"), ui.output_data_frame("subjects")),
    title="Trial Operations Dashboard",
)


def server(input, output, session):
    who = identity_from_headers(session.http_conn.headers)

    if REQUIRE_LOGIN and not who.verified:
        # Never serve data to a session we cannot attribute to a person.
        audit(who.name, "access_denied", sub=who.sub)

        @reactive.effect
        async def _deny():
            await session.close()

        return

    audit(who.name, "session_start", verified=who.verified, sub=who.sub)

    @reactive.calc
    def filtered() -> pd.DataFrame:
        df = DATA
        if input.site() != "All sites":
            df = df[df["site"] == input.site()]
        if input.arm() != "Both":
            df = df[df["arm"] == input.arm()]
        return df

    @reactive.effect
    @reactive.event(input.site, input.arm, ignore_init=True)
    def _log_filter():
        audit(who.name, "filter", site=input.site(), arm=input.arm())

    @render.ui
    def signed_in():
        status = "verified" if who.verified else "not verified"
        return ui.p(ui.tags.small(f"Signed in as {who.name} ({status})"))

    @render.text
    def kpi_enrolled():
        return f"{len(filtered()):,}"

    @render.text
    def kpi_visits():
        df = filtered()
        return f"{df['visits_completed'].mean():.1f}" if len(df) else "0"

    @render.text
    def kpi_ae():
        return f"{int(filtered()['adverse_events'].sum()):,}"

    @render.plot
    def enrolment():
        df = filtered()
        monthly = df.groupby(df["enrolled"].dt.to_period("M")).size()
        fig, ax = plt.subplots()
        ax.bar([p.strftime("%b") for p in monthly.index], monthly.values, color="#2F5D8A")
        ax.set_ylabel("Subjects")
        ax.spines[["top", "right"]].set_visible(False)
        return fig

    @render.data_frame
    def subjects():
        df = filtered().copy()
        df["enrolled"] = df["enrolled"].dt.strftime("%Y-%m-%d")
        return render.DataGrid(df, height="320px")


shiny_app = App(app_ui, server)


async def health(request):
    # Used by the load balancer. Kept dependency-free and fast.
    return PlainTextResponse("ok")


app = Starlette(routes=[Route("/health", health), Mount("/", app=shiny_app)])
