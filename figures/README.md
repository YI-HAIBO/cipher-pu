# Figures Directory

Paper figures and LaTeX table sources.

| Figure | Description | Files |
|--------|-------------|-------|
| Fig. 1 | System architecture overview | `fig1_architecture.{pdf,png}` |
| Fig. 2 | Three-tier DSE (S82/S90/S128) area-timing | `fig2_three_tier_dse.{pdf,png}` |
| Fig. 3 | Noise-budget evolution with DARE | `fig3_noise_budget_dare.{pdf,png}` |
| Fig. 4 | SOTA energy-efficiency comparison | `fig4_sota_efficiency.{pdf,png}` |
| Table 1-3 | Three-tier DSE / timing / SOTA | `table1_three_tier.tex`, `table2_spare_time.tex`, `table3_sota.tex` |

## Regenerating

```bash
python scripts/make_figures.py
```

`make_figures.py` is the single source of truth for all figures and tables;
it reads the experiment data in `../data/`.

## License

Apache-2.0. See [../LICENSE](../LICENSE).
