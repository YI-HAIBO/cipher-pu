# Security Policy

## Reporting a Vulnerability

We take the security of CIPHER-PU seriously. If you discover a security
vulnerability, please report it privately through the process below.

**Do not** report security vulnerabilities through GitHub Issues.

### Reporting Process

1. **Email**: Send details to `haiboyi@szpu.edu.cn`
2. **Include**:
   - Description of the vulnerability
   - Impact assessment (what can an attacker achieve)
   - Steps to reproduce (if applicable)
   - Suggested mitigation (if any)
3. **Response**: We will acknowledge receipt within 5 business days and provide
   an update on the investigation within 10 business days.
4. **Credit**: Unless you ask for anonymity, we will credit you in the
   acknowledgment when we release the fix.

### Scope

This policy applies to:

- RTL source code (`rtl/`)
- Testbenches (`tb/`)
- Simulation scripts (`scripts/`)
- IP core files (`ip_repo/`)

### Out of Scope

- Third-party libraries (report to their maintainers)
- Vendor toolchains (Vivado/xsim, etc.)
- Hardware vulnerabilities on Xilinx devices

### Security Best Practices

- Keep your repository up to date to receive security patches
- Use `git pull --rebase` to get the latest commits
- Run `make verify` after updating to ensure no regressions

### Vulnerability Disclosure

We follow the Coordinated Vulnerability Disclosure (CVD) process:

1. **Initial Contact**: Email to maintainer
2. **Triage**: 5 business days for initial response
3. **Assessment**: 10-30 days depending on complexity
4. **Patch Development**: 30-90 days typical
5. **Public Disclosure**: 90 days after initial report (or by mutual agreement)

### Bug Bounty

At this time, we do not offer a bug bounty program for CIPHER-PU. If you have
discovered a security-relevant bug, please report it through the process above.

---

**Version**: 1.0  
**Last Updated**: 2026-10-24
