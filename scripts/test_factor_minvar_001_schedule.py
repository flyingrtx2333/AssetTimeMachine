from pathlib import Path
import sys

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.factor_minvar_001_schedule import long_only_min_variance, schedule_from_prices


def test_long_only_solution():
    cov=np.array([[0.01,0.004,0.003,0.002],[0.004,0.04,0.006,0.004],[0.003,0.006,0.0225,0.003],[0.002,0.004,0.003,0.0144]])
    w=long_only_min_variance(cov)
    assert abs(w.sum()-1)<1e-12 and np.min(w)>=0
    assert float(w@cov@w) <= float(np.full(4,.25)@cov@np.full(4,.25)) + 1e-12


def test_execution_day_is_not_used():
    dates=[]
    import datetime
    d=datetime.date(2013,12,1)
    while len(dates)<800:
        if d.weekday()<5: dates.append(d.isoformat())
        d+=datetime.timedelta(days=1)
    # force a recognizable 2015 first common date window with stable positive prices
    t=np.arange(len(dates),dtype=float)
    prices=np.column_stack([100*np.exp(.0003*t+.002*np.sin(t/7+j)) for j in range(4)])
    base=schedule_from_prices(dates,prices)
    assert base
    first=base[0]
    idx=dates.index(first['date'])
    changed=prices.copy(); changed[idx,:]*=np.array([50,0.02,100,0.01])
    after=schedule_from_prices(dates,changed)
    assert base[0]['weights']==after[0]['weights']
    assert first['signal_end_date'] < first['date']


if __name__=='__main__':
    test_long_only_solution();test_execution_day_is_not_used();print('FACTOR_MINVAR_001_SCHEDULE_TEST_OK')
