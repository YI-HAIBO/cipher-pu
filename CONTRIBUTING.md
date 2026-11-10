# Contributing to CIPHER-PU

Thank you for considering contributing to CIPHER-PU! We welcome contributions of all kinds:

- Bug reports and bug fixes
- New features and enhancements
- Documentation improvements
- Testbench improvements
- Verification of results on different platforms

## Code of Conduct

By participating, you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md).

## Getting Started

1. Fork this repository
2. Clone your fork: `git clone https://github.com/YOUR_USER/cipher-pu.git`
3. Create a feature branch: `git checkout -b feature/your-feature`
4. Make your changes
5. Run the verification: `make verify`
6. Commit your changes: `git commit -m "feat: your feature description"`
7. Push to your fork: `git push origin feature/your-feature`
8. Open a Pull Request

## Development Environment

- **Vivado 2026.1** — Synthesis, implementation, power and xsim verification
- **Vivado xsim** — Functional simulation (no third-party simulator needed)
- **Python 3.11+** — Scripts, vector generation, benchmark
- **OpenFHE** (optional) — CKKS parameter cross-validation

## Coding Style

### SystemVerilog RTL

- **Naming**: `snake_case` for signals/ports, `SNAKE_CASE` for parameters
- **Indentation**: 4 spaces (no tabs)
- **Line width**: 100 characters max
- **Comments**: `//` for single-line, `/* */` for multi-line
- **Header template**:
  ```systemverilog
  /*
   * Module: <name>
   * Description: <brief>
   * Author: <name>, <institution>
   * License: Apache-2.0
   * Date: YYYY-MM-DD
   */
  ```

### Python Scripts

- PEP 8 compliant
- Type hints preferred
- Docstrings required for public functions
- No hardcoded paths — use argparse or environment variables

### Makefile

- Tab-indented recipes (not spaces)
- Variables UPPERCASE
- Phony targets listed at the top

## Testing

Before submitting a PR, please run:

```bash
make verify     # Functional simulation
make lint       # Lint check (if verilator available)
```

For substantial changes, please:
1. Add or update testbench coverage
2. Update relevant documentation
3. Regenerate paper figures if applicable

## Pull Request Guidelines

1. **Title**: `<type>(<scope>): <short description>`
   - Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `perf`, `build`
   - Example: `feat(rtl/m4): add adaptive noise monitor threshold config`

2. **Description**:
   - What does this PR change?
   - Why is this change needed?
   - How was it verified?

3. **Checklist**:
   - [ ] Code follows project style
   - [ ] Tests added or updated
   - [ ] Documentation updated
   - [ ] No breaking changes (or breaking changes documented)
   - [ ] Cross-referenced issues closed

## Reporting Issues

- Use the [Bug Report](https://github.com/cipher-pu/cipher-pu/issues/new?template=bug_report.md) template for bugs
- Use the [Feature Request](https://github.com/cipher-pu/cipher-pu/issues/new?template=feature_request.md) template for new features
- Use the [Question](https://github.com/cipher-pu/cipher-pu/issues/new?template=question.md) template for questions

Please include:
- Vivado version
- Device target (xcau25p or other)
- CKKS parameters (N, Q_WIDTH, LOG_N)
- Steps to reproduce (for bugs)

## Research Reproducibility

All experiments are documented in `reports/experiments/`. If you replicate a result and find discrepancies, please:
1. Open an issue
2. Include your simulation environment (Vivado version, device, tool version)
3. Attach relevant logs and waveforms

## Communication

- Prefer GitHub Issues for technical discussions
- Respectful, constructive communication (see Code of Conduct)
- Response time: ~2 weeks for bug reports, ~1 month for feature proposals

## License

By contributing, you agree that your contributions will be licensed under the same [Apache License 2.0](LICENSE) as this project.

---

Thank you for contributing to CIPHER-PU! 🚀
