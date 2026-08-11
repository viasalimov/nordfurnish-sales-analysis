# NordFurnish — Retail Sales & Profitability Analysis

End-to-end analytics project on a US furniture retailer over 2014 to 2017. Data cleaning and analysis in **SQL (BigQuery)**, an interactive **Power BI** report, and a **Python** linear-regression model for profit prediction.

The dataset is a Superstore-derived furniture retail set of roughly 2,100 sales, 700 customers and 4 US regions. I branded it as the fictional retailer *NordFurnish* for presentation.

---

## Key finding

The business is profitable overall at about 2.5% margin, but discounts above 25% erase that margin. Almost all of the loss sits in one sub-category, Tables, which is unprofitable in every region.

Capping discounts at 25% could recover up to roughly $54K in profit, because sales discounted beyond that point account for the entire loss.

I confirmed this three independent ways.

* By discount band, margin turns negative past 25% and then falls sharply.
* By category, Tables lose money in all four regions while Chairs and Furnishings carry the business.
* By regression, discount is the dominant negative driver of profit with a coefficient of −359 and a correlation of −0.48.

A few more insights came out of the analysis.

* Depth of discount matters more than frequency. Chairs are discounted as often as Tables but shallowly, so they stay profitable.
* Revenue rankings hide losses. Top cities like NYC and LA are healthy, but small cities such as Concord, Fairfield and Aurora lose money invisibly, and Philadelphia is high-revenue yet loss-making.
* Revenue is seasonal. A February low and a Q4 peak repeat across all four years on top of steady growth.
* The customer base is low-frequency at about 2.5 orders per customer, with 74% still active. Retention matters more than upselling here.

---

## Repository structure

```
├── sql/
│   └── analysis.sql          BigQuery staging layer (cleaned views) plus 6 analysis queries
├── powerbi/
│   └── NordFurnish_dashboard.pbix   6-page interactive report with drill-through and a what-if simulator
|   └── Final project n!.pdf   Power BI dashboard export (PDF)
├── python/
│   └── profit_regression.ipynb      EDA plus linear regression (profit from sales, discount, quantity)
├── data/
│   ├── customers.csv, orders.csv, products.csv, sales.csv   raw source tables
│   ├── orders_full.csv       unified table (all 4 joined), used by Power BI and Python
│   └── forecast.csv          orders_full with a predicted-profit column
└── README.md
```

---

## SQL — data preparation (BigQuery)

I built a staging layer so the raw tables stay untouched and the cleaned versions live as separate views. Several data-quality issues turned up along the way.

**Customers** had 1,754 rows but only 707 unique customers, since each had 2 to 4 addresses. I kept one address per customer using a deterministic hash (`FARM_FINGERPRINT`) instead of the minimum ZIP code. US ZIP codes are geographic, so picking the min ZIP biased the region split and dropped West from 590 records down to 98. The hash keeps the choice reproducible without that bias.

**Orders** had 2,121 rows against 1,764 unique orders. The extras were exact copies, removed with `DISTINCT`.

**Products** had 8 `product_id` values that each pointed to two different products. That is a key violation, and on joining to sales it inflated revenue by about 3% through row fan-out, so I deduplicated it. Separately, three product names were shared across different ids. Those I kept, because the key isn't violated and they are legitimately different products.

**Sales** had one fully duplicated row, removed to land at 2,120.

The dataset has a single category (Furniture), so all category analysis is done at the sub-category level (Chairs, Tables, Bookcases, Furnishings).

Six analysis queries follow. Top products by revenue, average discount by region, loyal customers using an RFM approach with a churn threshold derived from real inter-order gaps, profit by sub-category using margin rather than absolute profit, discounted-sales share, and the unified table.

## Power BI — interactive report

Six pages on a custom theme, connected to the cleaned views as a star schema of four related tables.

* **Overview** with KPIs and the headline insight
* **Discount & Profitability** with a scatter, margin bands and a frequency-vs-depth comparison
* **Products & Regions** with a profit matrix, a sales map, loss-making products and top/bottom cities
* **Customers & Time** with seasonality, segment analysis and an active-vs-lapsed breakdown
* **SQL Results** showing the six query outputs
* **Discount Cap Simulator**, a what-if parameter that models the profit recovered at a chosen discount ceiling
* a hidden **Region Detail** drill-through page

Interactive features include synced slicers for year, month, region and segment, drill-through to region detail, a discounted-only toggle, a category-driven trend, and button navigation between pages.

## Python — profit prediction

A linear regression predicting profit from sales, discount and quantity, built with scikit-learn.

The discount coefficient came out at −359, the dominant negative driver, which works out to roughly −$36 of profit for every 10 points of discount. The model's R² is 0.26. It captures the discount effect, but profitability also depends on variables the model doesn't see, such as purchase cost and category. That lines up with the structurally loss-making products found in Power BI. Predictions are saved to forecast.csv and compared against actuals back in the report.

---

## Tools

SQL (BigQuery), Power BI (DAX, Power Query), Python (pandas, matplotlib, seaborn, scikit-learn).
