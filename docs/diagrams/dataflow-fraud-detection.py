"""
Data flow — Use Case 2: Fraud detection.

This was the project's original illustrative example (see ARCHITECTURE.md) and remains a valid
secondary use case on the same platform. Unlike NBA/NBO (Use Case 1), the decision here
(block/flag a transaction) sits under existing fraud-ops authority, not a credit decision —
so it does not carry the fair-lending/adverse-action review question raised in ADR-0012, and
is drawn as a normal in-scope Flink/Lambda step rather than an open one.

Regenerate: python3 dataflow-fraud-detection.py
"""

from diagrams import Diagram, Edge
from diagrams.aws.analytics import ManagedStreamingForKafka, KinesisDataAnalytics
from diagrams.aws.compute import Lambda
from diagrams.aws.database import ElastiCache
from diagrams.aws.storage import S3
from diagrams.aws.integration import SNS
from diagrams.aws.general import Users
from diagrams.onprem.database import Oracle

graph_attr = {"fontsize": "20", "bgcolor": "white", "pad": "0.5", "splines": "spline"}

with Diagram(
    "Use Case 2 — Fraud Detection",
    filename="dataflow-fraud-detection",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
):
    source = Oracle("Card/transaction\nCDC feed (GoldenGate)")
    topic = ManagedStreamingForKafka("MSK topic:\ntransaction-events\n(same stream as NBA/NBO)")
    flink = KinesisDataAnalytics("Flink: fraud\nrules engine /\nanomaly scoring")
    redis = ElastiCache("Redis:\nreal-time block/\nwatch list")
    route = Lambda("Lambda:\nrouting to\nfraud-ops queue")
    sns = SNS("SNS: fraud-ops\nalert")
    ops = Users("Fraud operations\nteam")
    audit = S3("Iceberg audit trail\n(general 7-day-configurable\nODS, ADR-0007)")

    source >> Edge(label="1. CDC") >> topic
    topic >> Edge(label="2. consume") >> flink
    flink >> Edge(label="3. score transaction") >> redis
    flink >> Edge(label="4a. flagged") >> route
    route >> Edge(label="5. alert") >> sns
    sns >> Edge(label="6. review") >> ops
    flink >> Edge(label="4b. every scored txn\n(flagged or not)") >> audit
