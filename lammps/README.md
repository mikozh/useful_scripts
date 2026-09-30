

`install-lammps-hydrocarbons-cc75.sh1` -- LAMMPS installation on device with T1200 (turing card) having compute capability 7.5

```
chmod +x install-lammps-hydrocarbons.sh

sudo bash ./install-lammps-hydrocarbons.sh
```

After installation return to your normal user and prepare venv
```
cd /path/to/your/hydrocarbon-project

python3 -m venv .venv
. .venv/bin/activate

python -m pip install --upgrade pip

python -m pip install \
    numpy \
    pandas \
    matplotlib \
    moltemplate \
    pytest
```
