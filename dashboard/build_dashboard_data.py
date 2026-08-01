from __future__ import annotations

import csv
import json
from collections import Counter, defaultdict
from datetime import datetime
from decimal import Decimal
from pathlib import Path


PROJECT_DIR = Path(__file__).resolve().parents[1]
DATA_DIR = PROJECT_DIR / "data"
OUT_FILE = Path(__file__).resolve().parent / "dashboard_data.js"

COMMERCIAL_EXCLUDED_STATUSES = {"canceled", "unavailable"}


def read_csv(name: str) -> list[dict[str, str]]:
    with (DATA_DIR / name).open(newline="", encoding="utf-8-sig") as file:
        return list(csv.DictReader(file))


def parse_datetime(value: str | None) -> datetime | None:
    if not value:
        return None
    return datetime.strptime(value, "%Y-%m-%d %H:%M:%S")


def as_float(value: Decimal | float | int | None) -> float | None:
    if value is None:
        return None
    return round(float(value), 4)


def month_between(start: datetime, end: datetime) -> list[str]:
    months: list[str] = []
    year, month = start.year, start.month
    while (year, month) <= (end.year, end.month):
        months.append(f"{year:04d}-{month:02d}")
        month += 1
        if month == 13:
            month = 1
            year += 1
    return months


def main() -> None:
    customers = read_csv("olist_customers_dataset.csv")
    orders = read_csv("olist_orders_dataset.csv")
    items = read_csv("olist_order_items_dataset.csv")
    payments = read_csv("olist_order_payments_dataset.csv")
    reviews = read_csv("olist_order_reviews_dataset.csv")
    products = read_csv("olist_products_dataset.csv")
    sellers = read_csv("olist_sellers_dataset.csv")
    translations = read_csv("product_category_name_translation.csv")

    customer_by_id = {row["customer_id"]: row for row in customers}
    order_by_id = {row["order_id"]: row for row in orders}
    product_by_id = {row["product_id"]: row for row in products}
    seller_by_id = {row["seller_id"]: row for row in sellers}
    category_translation = {
        row["product_category_name"]: row["product_category_name_english"]
        for row in translations
    }

    order_item_rows: dict[str, list[dict[str, str]]] = defaultdict(list)
    order_revenue: dict[str, Decimal] = defaultdict(Decimal)
    order_freight: dict[str, Decimal] = defaultdict(Decimal)
    order_item_count: Counter[str] = Counter()

    category_set: set[str] = set()
    seller_set: set[str] = set()

    for row in items:
        order = order_by_id.get(row["order_id"])
        if not order or order["order_status"] in COMMERCIAL_EXCLUDED_STATUSES:
            continue

        product = product_by_id.get(row["product_id"], {})
        source_category = product.get("product_category_name") or "unknown"
        category = category_translation.get(source_category, source_category or "unknown")
        seller_id = row["seller_id"]

        price = Decimal(row["price"])
        freight = Decimal(row["freight_value"])

        prepared = {
            "order_id": row["order_id"],
            "category": category,
            "seller_id": seller_id,
            "price": str(price),
            "freight": str(freight),
        }
        order_item_rows[row["order_id"]].append(prepared)
        order_revenue[row["order_id"]] += price
        order_freight[row["order_id"]] += freight
        order_item_count[row["order_id"]] += 1
        category_set.add(category)
        seller_set.add(seller_id)

    review_scores: dict[str, list[int]] = defaultdict(list)
    for row in reviews:
        if row["review_score"]:
            review_scores[row["order_id"]].append(int(row["review_score"]))

    all_order_dates = [
        parse_datetime(order["order_purchase_timestamp"])
        for order in orders
        if order["order_purchase_timestamp"]
    ]
    all_order_dates = [date for date in all_order_dates if date is not None]

    commercial_dates = [
        parse_datetime(order["order_purchase_timestamp"])
        for order in orders
        if order["order_status"] not in COMMERCIAL_EXCLUDED_STATUSES
        and order["order_id"] in order_revenue
    ]
    commercial_dates = [date for date in commercial_dates if date is not None]
    first_date = min(all_order_dates)
    last_date = max(all_order_dates)

    months = month_between(first_date, last_date)
    month_index = {month: index for index, month in enumerate(months)}

    states = sorted({
        customer_by_id[order["customer_id"]]["customer_state"]
        for order in orders
        if order["order_id"] in order_revenue and order["customer_id"] in customer_by_id
    })
    state_index = {state: index for index, state in enumerate(states)}

    categories = sorted(category_set)
    category_index = {category: index for index, category in enumerate(categories)}

    seller_list = sorted(seller_set)
    seller_index = {seller_id: index for index, seller_id in enumerate(seller_list)}
    sellers_payload = [
        {
            "id": seller_id,
            "state": seller_by_id.get(seller_id, {}).get("seller_state", "NA"),
            "city": seller_by_id.get(seller_id, {}).get("seller_city", "unknown"),
        }
        for seller_id in seller_list
    ]

    customer_unique_index: dict[str, int] = {}
    orders_payload: list[list[object]] = []
    order_index_by_id: dict[str, int] = {}

    for order in sorted(orders, key=lambda row: row["order_purchase_timestamp"]):
        order_id = order["order_id"]
        if order["order_status"] in COMMERCIAL_EXCLUDED_STATUSES or order_id not in order_revenue:
            continue

        customer = customer_by_id.get(order["customer_id"])
        purchase_date = parse_datetime(order["order_purchase_timestamp"])
        delivered_date = parse_datetime(order["order_delivered_customer_date"])
        estimated_date = parse_datetime(order["order_estimated_delivery_date"])
        if customer is None or purchase_date is None:
            continue

        unique_id = customer["customer_unique_id"]
        if unique_id not in customer_unique_index:
            customer_unique_index[unique_id] = len(customer_unique_index)

        delivery_days = None
        delayed = None
        if delivered_date is not None:
            delivery_days = (delivered_date - purchase_date).total_seconds() / 86400
            if estimated_date is not None:
                delayed = 1 if delivered_date > estimated_date else 0

        scores = review_scores.get(order_id, [])
        review_score = sum(scores) / len(scores) if scores else None

        order_idx = len(orders_payload)
        order_index_by_id[order_id] = order_idx

        orders_payload.append([
            order_idx,
            month_index[purchase_date.strftime("%Y-%m")],
            state_index[customer["customer_state"]],
            customer_unique_index[unique_id],
            as_float(order_revenue[order_id]),
            as_float(order_freight[order_id]),
            order_item_count[order_id],
            as_float(delivery_days),
            delayed,
            as_float(review_score),
        ])

    items_payload: list[list[object]] = []
    for order_id, order_items in order_item_rows.items():
        if order_id not in order_index_by_id:
            continue
        for row in order_items:
            items_payload.append([
                order_index_by_id[order_id],
                category_index[row["category"]],
                seller_index[row["seller_id"]],
                as_float(Decimal(row["price"])),
                as_float(Decimal(row["freight"])),
            ])

    payments_payload: list[list[object]] = []
    for row in payments:
        order_id = row["order_id"]
        if order_id not in order_index_by_id:
            continue
        order_idx = order_index_by_id[order_id]
        order_row = orders_payload[order_idx]
        payments_payload.append([
            order_idx,
            order_row[1],
            row["payment_type"] or "unknown",
            int(row["payment_installments"] or 0),
            as_float(Decimal(row["payment_value"] or "0")),
        ])

    payload = {
        "meta": {
            "periodStart": first_date.strftime("%Y-%m-%d"),
            "periodEnd": last_date.strftime("%Y-%m-%d"),
            "currency": "BRL",
            "orderColumns": [
                "order_idx",
                "month_idx",
                "state_idx",
                "customer_idx",
                "revenue",
                "freight",
                "item_count",
                "delivery_days",
                "delayed",
                "review_score",
            ],
            "itemColumns": ["order_idx", "category_idx", "seller_idx", "price", "freight"],
            "paymentColumns": ["order_idx", "month_idx", "payment_type", "installments", "payment_value"],
        },
        "months": months,
        "states": states,
        "categories": categories,
        "sellers": sellers_payload,
        "orders": orders_payload,
        "items": items_payload,
        "payments": payments_payload,
    }

    OUT_FILE.write_text(
        "window.OLIST_DASHBOARD_DATA = "
        + json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
        + ";\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
