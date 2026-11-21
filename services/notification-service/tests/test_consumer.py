import json
import logging
from types import SimpleNamespace

import pytest

from app import main


def record(value, headers=None, offset=0):
    return SimpleNamespace(value=value, headers=headers, topic=main.TOPIC, partition=0, offset=offset)


def event(**fields):
    return json.dumps({"orderId": "o-1", "userEmail": "asha@x.in", **fields}).encode()


@pytest.fixture
def sent(monkeypatch):
    """Capture send_email calls instead of sleeping/"sending"."""
    calls = []
    monkeypatch.setattr(main, "send_email", lambda to, template, data: calls.append((to, template, data["orderId"])))
    return calls


def counter(name, **labels):
    from prometheus_client import REGISTRY

    return REGISTRY.get_sample_value(name, labels) or 0


def test_order_placed_sends_confirmation(sent):
    before = counter("notification_events_total", event="order.placed", result="ok")
    main.handle(record(event(type="order.placed")))
    assert sent == [("asha@x.in", "order_confirmation", "o-1")]
    assert counter("notification_events_total", event="order.placed", result="ok") == before + 1


def test_order_failed_sends_payment_failed(sent):
    main.handle(record(event(type="order.failed", userEmail=None)))
    assert sent == [("unknown", "payment_failed", "o-1")]


def test_unknown_event_type_is_acknowledged_without_email(sent):
    main.handle(record(event(type="order.shipped")))
    assert sent == []


def test_bad_json_is_counted_and_skipped(sent):
    before = counter("notification_events_total", event="unknown", result="error")
    main.handle(record(b"not-json", offset=42))  # must not raise: one bad record can't stop the consumer
    assert sent == []
    assert counter("notification_events_total", event="unknown", result="error") == before + 1


def test_trace_context_headers_are_continued(monkeypatch):
    trace_id = "4bf92f3577b34da6a3ce929d0e0e4736"
    headers = [("traceparent", f"00-{trace_id}-00f067aa0ba902b7-01".encode()), ("empty", None)]
    seen = {}

    def capture(to, template, data):
        ctx = main.trace.get_current_span().get_span_context()
        seen["trace_id"] = format(ctx.trace_id, "032x")

    monkeypatch.setattr(main, "send_email", capture)
    main.handle(record(event(type="order.placed"), headers=headers))
    # The consumer span continues the producer's trace (order-service -> Kafka -> here is one trace).
    assert seen["trace_id"] == trace_id


def test_send_email_records_metrics(monkeypatch):
    monkeypatch.setattr(main.time, "sleep", lambda _s: None)
    before = counter("notifications_sent_total", channel="email", template="order_confirmation")
    main.send_email("a@x.in", "order_confirmation", {"orderId": "o-2"})
    assert counter("notifications_sent_total", channel="email", template="order_confirmation") == before + 1


def test_json_log_format_includes_extra_fields():
    rec = logging.LogRecord("t", logging.INFO, __file__, 1, "email sent", None, None)
    rec.extra_fields = {"orderId": "o-1"}
    out = json.loads(main.JsonFormatter().format(rec))
    assert out["msg"] == "email sent"
    assert out["level"] == "info"
    assert out["service"] == main.SERVICE
    assert out["orderId"] == "o-1"
