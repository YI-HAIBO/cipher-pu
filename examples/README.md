# Examples Directory

End-to-end usage examples for CIPHER-PU.

## Available Examples

### 1. run_e2e_sim.py
Run end-to-end CKKS inference simulation with MNIST data.

```bash
python examples/run_e2e_sim.py --batch-size 32 --seed 42
```

### 2. mnist_inference.py
Deploy MNIST inference on encrypted data.

```bash
python examples/mnist_inference.py --model lenet --seed 42
```

### 3. cifar10_inference.py
Deploy CIFAR-10 inference on encrypted data (batch=16).

```bash
python examples/cifar10_inference.py --model resnet18 --seed 42
```

### 4. compare_with_openfhe.py
Cross-validate with OpenFHE reference implementation.

```bash
python examples/compare_with_openfhe.py --scheme CKKS --seed 42
```

## Prerequisites

- Python 3.11+ with `numpy`, `scipy`, `matplotlib`
- (Optional) OpenFHE for cross-validation
- (Optional) MNIST/CIFAR-10 dataset (downloadable via examples)

## Data Sources

- MNIST: http://yann.lecun.com/exdb/mnist/ (Public Domain)
- CIFAR-10: https://www.cs.toronto.edu/~kriz/cifar-10.html (CC-BY-4.0)

## Expected Outputs

- Inference accuracy (encrypted vs. plaintext)
- Latency per batch
- Noise budget utilization
- DARE bootstrap frequency

## License

Apache-2.0. See [../LICENSE](../LICENSE).
