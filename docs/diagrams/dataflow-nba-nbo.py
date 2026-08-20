"""
Data flow — Use Case 1: Real-time Next Best Action / Next Best Offer (NBA/NBO).

Primary driving use case for this platform (see ARCHITECTURE.md). The offer-decisioning step
itself is drawn as a generic/greyed icon because its scope is still an open architecture
decision — see docs/architecture-decisions/0012-real-time-offer-decisioning-scope.md.
Everything upstream of it (MSK -> Flink windowed pattern detection -> Redis) is built the
same way regardless of how that ADR resolves.

Regenerate: python3 dataflow-nba-nbo.py
"""

from diagrams import Diagram, Cluster, Edge
from diagrams.aws.analytics import ManagedStreamingForKafka, KinesisDataAnalytics
from diagrams.aws.database import ElastiCache
from diagrams.aws.storage import S3
from diagrams.aws.integration import SNS
from diagrams.aws.engagement import SES
from diagrams.aws.general import GenericSDK, MobileClient
from diagrams.onprem.database import Oracle

graph_attr = {"fontsize": "20", "bgcolor": "white", "pad": "0.5", "splines": "spline"}

with Diagram(
    "Use Case 1 — Real-Time NBA/NBO (Next Best Offer)",
    filename="dataflow-nba-nbo",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
):
    source = Oracle("Card/transaction\nCDC feed (GoldenGate)")
    topic = ManagedStreamingForKafka("MSK topic:\ntransaction-events")
    flink = KinesisDataAnalytics(
        "Flink: windowed\npattern detection\n(spend velocity,\nlarge one-off purchase)"
    )
    redis = ElastiCache("Redis:\ncustomer eligibility /\nprofile state")

    decision = GenericSDK(
        "Offer decision logic\n(eligibility + terms)\nscope OPEN — ADR-0012\nnot yet built here"
    )

    sns = SNS("SNS (push / in-app)")
    ses = SES("SES (email)")
    mobile = MobileClient("Customer's\nmobile/banking app")
    audit = S3("Iceberg audit trail\n(decision-record tier,\nretention: TBD per ADR-0012)")

    source >> Edge(label="1. CDC") >> topic
    topic >> Edge(label="2. consume") >> flink
    flink >> Edge(label="3. read/write\neligibility state") >> redis
    flink >> Edge(label="4. pattern qualifies") >> decision
    decision >> Edge(label="5a. approved offer", style="dashed") >> sns
    decision >> Edge(label="5b. approved offer", style="dashed") >> ses
    sns >> Edge(label="6. notification") >> mobile
    ses >> Edge(label="6. notification") >> mobile
    decision >> Edge(label="7. record\n(who/what/why)", style="dashed") >> audit
