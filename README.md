# RootService tuning-primer (POSIX shell)

This repository is a **POSIX sh** implementation derived from the upstream **MySQLTuner-perl** project.

## License

This project is licensed under the **GNU GPL v3**.

- Full text: `LICENSE.GPLv3`

## Usage (planned)

```sh
./mysqltuner.sh --help
```

## Notes

- Goal: feature parity with MySQLTuner-perl, but implemented in portable POSIX shell (no bashisms).
- Data files used by checks:
  - `basic_passwords.txt`
  - `vulnerabilities.csv`
