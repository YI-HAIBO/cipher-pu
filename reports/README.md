# Reports Directory

Experiment reports and paper artifacts for CIPHER-PU.

## Structure

```
reports/
├── experiments/            # experiment reports E1-E39 (see ../data/)
├── figures/                # paper figures (PDF/PNG) + LaTeX tables
├── paper_tcas_en.md        # IEEE TCAS-I submission manuscript (authoritative)
└── paper_tcas_draft.md     # earlier working snapshot (Chinese/English mixed)
```

## Experiments

39 experiments (E1-E39). `../data/experiment_summary.md` gives the full
overview; the machine-readable results sit in `../data/`.

## Paper

The IEEE TCAS-I submission manuscript is `paper_tcas_en.md`. Sections of
particular note:

- Sec. 4 - runtime noise-adaptive closed loop
- Sec. 7 - security-hardware alignment (three-tier DSE, device ceiling)
- Sec. 7.8 - RTL side-channel evaluation and first-order masking (E39)
- Sec. 8.3 - routed SAIF gate-level power (0.698 W anchor)
- Sec. 8.6 - real-RLWE ciphertext execution on the RTL datapath (E33)

## License

Apache-2.0. See [../LICENSE](../LICENSE).
