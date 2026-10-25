#!/usr/bin/env python3
"""Reproducible native v0.2 acceptance. Isolated fixtures only; never uses the user's home.
Run from any directory after scripts/bundle.sh. Evidence: .devpanel-dev/codex/c-*.
No application install, launch agent install, or signals by process name/port.
"""
from pathlib import Path
import json, os, shutil, signal, subprocess, sys, time, urllib.request

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / '.devpanel-dev/codex'
HOME = OUT / 'acc'
FIX = OUT / 'acceptance-project'
APP = ROOT / 'apps/mac/build/DevPanel.app/Contents/MacOS/DevPanel'
NODE = shutil.which('node')
ENV = dict(os.environ, DEVPANEL_HOME=str(HOME), DEVPANEL_PORT='0')
CLI = [NODE, str(ROOT / 'packages/cli/src/main.ts')]
checks = []
owned = []
project_id = None
owns_home = False


def write(name, value):
    (OUT / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def check(name, condition, **evidence):
    checks.append(dict(name=name, passed=bool(condition), **evidence))
    write('c-results.json', checks)
    print(('PASS ' if condition else 'FAIL ') + name, flush=True)
    if not condition:
        raise AssertionError(name)


def identity(pid):
    r = subprocess.run(['ps', '-p', str(pid), '-o', 'pid=,lstart=,command='], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def spawn(args, name, env=None):
    log = open(OUT / (name + '.log'), 'w')
    process = subprocess.Popen([str(a) for a in args], cwd=ROOT, env=env or ENV, stdout=log, stderr=subprocess.STDOUT)
    ident = identity(process.pid)
    owned.append((process, ident, log))
    return process


def wait(process, seconds=90):
    try:
        return process.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        stop_owned(process)
        raise


def stop_owned(process):
    entry = next(x for x in owned if x[0] is process)
    if process.poll() is None and entry[1] and identity(process.pid) == entry[1]:
        os.kill(process.pid, signal.SIGTERM)
        process.wait(timeout=10)


def cli(*args, expected=0):
    r = subprocess.run(CLI + list(args), cwd=ROOT, env=ENV, capture_output=True, text=True)
    with open(OUT / 'c-cli.log', 'a') as f:
        f.write('$ devpanel ' + ' '.join(args) + '\n' + r.stdout + r.stderr + '\n')
    if r.returncode != expected:
        raise AssertionError(f'CLI {args}: {r.returncode}, {r.stdout} {r.stderr}')
    try:
        return json.loads(r.stdout)
    except ValueError:
        return r.stdout


def api(method, route, body=None):
    discovery = json.loads((HOME / 'daemon.json').read_text())
    req = urllib.request.Request('http://127.0.0.1:' + str(discovery['httpPort']) + '/api/v1' + route,
        data=json.dumps(body).encode() if body is not None else None, method=method,
        headers={'Authorization': 'Bearer ' + discovery['token'], 'X-DevPanel-Client': 'ui', 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=45) as response:
        data = response.read()
        return json.loads(data) if data else None


def shot(name, *args, expected=0, asynchronous=False):
    p = spawn([APP, '--snapshot', OUT / (name + '.png'), '--report-state', OUT / (name + '.json'), *args], name)
    if asynchronous:
        return p
    rc = wait(p)
    check(name + ' renderer', rc == expected, exit=rc)
    return json.loads((OUT / (name + '.json')).read_text())


def service(view, name):
    return next(s for s in view['services'] if s['id'] == name)


def status():
    return cli('status', project_id, '--json')


def alive_records():
    records = []
    for s in status()['services']:
        if s['currentRun']:
            run = api('GET', '/runs/' + s['currentRun']['id'])
            for proc in run['processes']:
                records.append(dict(**proc, osIdentity=identity(proc['pid']), runId=run['id']))
    return records


def verify_gone(records):
    # A reused PID is not the same process. Never signal an unknown identity.
    remaining = [r for r in records if r['osIdentity'] and identity(r['pid']) == r['osIdentity']]
    check('recorded managed identities exited', not remaining, identities=records, remaining=remaining)


def patch_config(change):
    p = api('GET', '/projects/' + project_id)
    change(p['config'])
    return api('PUT', '/projects/' + project_id, {'ifRevision': p['revision'], 'config': p['config']})


def cpu_seconds(text):
    pieces = text.split(':')
    return sum(float(n) * 60 ** i for i, n in enumerate(reversed(pieces)))


def sample(pid):
    r = subprocess.run(['ps', '-p', str(pid), '-o', 'time=,rss='], capture_output=True, text=True)
    parts = r.stdout.split()
    if len(parts) != 2:
        raise AssertionError('sampling process disappeared')
    return dict(time=time.monotonic(), cpu=cpu_seconds(parts[0]), rssKiB=int(parts[1]))


def footprint(name, *view_args, target=None):
    """Foreground release window, 7s warm-up + 16s CPU delta; services included."""
    log_name = 'c-window-resource-' + name
    p = spawn([APP, '--snapshot', OUT / (name + '.png'), '--bench-visible',
               '--layout', 'overview', '--appearance', 'dark', '--delay', '32', *view_args], log_name)
    deadline = time.monotonic() + 25
    log_path = OUT / (log_name + '.log')
    while 'event=before-delay' not in log_path.read_text() and time.monotonic() < deadline:
        if p.poll() is not None: raise AssertionError(log_path.read_text())
        time.sleep(.1)
    if '--ui-cpu' in sys.argv and '--bench-minimized' not in view_args:
        subprocess.run([str(ROOT / '.devpanel-dev/codex/ui-cpu/activate'), str(p.pid)], check=True)
    time.sleep(7)
    daemon_pid = json.loads((HOME / 'daemon.json').read_text())['pid']
    rows = []
    for i in range(5):
        rows.append(dict(app=sample(p.pid), daemon=sample(daemon_pid)))
        if i < 4: time.sleep(4)
    result = {}
    for who in ['app', 'daemon']:
        first, last = rows[0][who], rows[-1][who]
        result[who] = dict(cpuPercent=round((last['cpu']-first['cpu'])/(last['time']-first['time'])*100, 3),
                           rssMiB=round(sum(r[who]['rssKiB'] for r in rows)/len(rows)/1024, 2))
    if target is not None and result['app']['cpuPercent'] > target:
        subprocess.run(['sample', str(p.pid), '5', '-file', str(OUT / (name + '-sample.txt'))],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    check(name + ' renderer', wait(p) == 0)
    focus = [line for line in log_path.read_text().splitlines() if line.startswith('bench-focus:')]
    measured_start, measured_end = rows[0]['app']['time'], rows[-1]['app']['time']
    within = [line for line in focus if measured_start <= float(line.split('uptime=')[1].split()[0]) <= measured_end]
    before = [line for line in focus if float(line.split('uptime=')[1].split()[0]) <= measured_start]
    endpoints = before[-1:] + within
    minimized = '--bench-minimized' in view_args
    valid = bool(endpoints) and all(
        ('minimized=true' in line) if minimized else
        ('appActive=true' in line and 'visible=true' in line and 'occluded=false' in line and 'onScreen=true' in line)
        for line in endpoints)
    write('c-resource-' + name + '-samples.json', dict(result=result, samples=rows, focus=focus,
        valid=valid, target=target, note='release; foreground/on-screen except minimized; 7s warm-up + 16s CPU delta; services included'))
    check('real window release footprint ' + name, valid, **result)
    return result


def run():
    global project_id, owns_home
    OUT.mkdir(parents=True, exist_ok=True)
    if HOME.exists():
        raise RuntimeError('Acceptance home already exists; inspect/clean the previous isolated run before rerunning')
    HOME.mkdir(mode=0o700)
    owns_home = True
    (OUT/'c-cli.log').write_text('')
    FIX.mkdir(exist_ok=True)
    (FIX / 'keep-me.txt').write_text('Project source must survive removal.\n')
    marker = FIX / 'exit-now'
    marker.unlink(missing_ok=True)
    check('short isolated socket path', len(str(HOME / 'run/devpanel.sock').encode()) <= 103, bytes=len(str(HOME / 'run/devpanel.sock').encode()))
    setup = subprocess.run([NODE, str(ROOT / 'packages/cli/src/setup-cli.ts'), '--bin-dir', str(OUT/'bin')], cwd=ROOT, env=ENV, capture_output=True, text=True)
    check('temporary CLI installation', setup.returncode == 0)
    shot('c-daemon-not-running', '--timeout', '1', expected=3)
    started = shot('c-launch-daemon', '--timeout', '1', '--launch-cli', str(OUT/'bin/devpanel'), '--delay', '3')
    check('native launcher starts only daemon', started['status'] == 'connected' and started['projects'] == [])
    daemon = api('GET', '/daemon')
    write('c-daemon-identity.json', dict(pid=daemon['pid'], startedAt=daemon['startedAt'], osIdentity=identity(daemon['pid'])))
    footprint('idle')
    fixture = ROOT / 'packages/daemon/test/fixtures'
    config = dict(schemaVersion=1, name='DevPanel v0.2 验收', root=str(FIX), params=[
        dict(key='port', label='监听端口', type='number', value=0, min=0, max=65535, description='0 由系统分配空闲端口；显示值来自真实 LISTEN 套接字。'),
        dict(key='host', label='监听地址', type='enum', value='127.0.0.1', description='控制监听网卡', choices=[dict(value='127.0.0.1', label='仅本机'), dict(value='0.0.0.0', label='所有网卡')]),
        dict(key='mode', label='进程模式', type='enum', value='tree-ignore', choices=[dict(value='tree-ignore'), dict(value='slowstop')], description='验收派生进程与停止超时'),
    ], services=[
        dict(id='listen', name='监听服务', cwd='.', command=[NODE,str(fixture/'listening.mjs'),'${host}','${port}'],stopTimeoutSec=1),
        dict(id='tree', name='进程树', cwd='.', command=[NODE,str(fixture/'service.mjs'),'${mode}'],stopTimeoutSec=1),
        dict(id='exit', name='异常退出', cwd='.', command=[NODE,str(fixture/'service.mjs'),'exit-on-file'],stopTimeoutSec=1),
    ])
    conf = OUT/'acceptance-config.json'; conf.write_text(json.dumps(config,ensure_ascii=False))
    registered=cli('project','register','--config',str(conf),'--json'); project_id=registered['project']['id']
    check('AI registration does not execute', all(s['currentRun'] is None for s in status()['services']), projectId=project_id)
    duplicate=cli('project','register','--config',str(conf),'--json')
    check('same root register is idempotent', duplicate['created'] is False and duplicate['project']['id']==project_id)
    shot('c-registered-options','--select',project_id+'/listen','--tab','options')
    cli('start',project_id,'--json')
    view=status(); ids={s['id']:s['currentRun']['id'] for s in view['services']}
    report=shot('c-cli-start-native-logs','--select',project_id+'/listen','--tab','logs','--delay','3')
    native=next(p for p in report['projects'] if p['id']==project_id)
    sample_listen=report['stats']['projects'][project_id]['services']['listen']
    check('CLI and native share run logs resources and real port', service(native,'listen')['currentRun']['id']==ids['listen'] and report['logLines']>0 and sample_listen['rssBytes']>0 and any(x['address']=='127.0.0.1' for x in sample_listen['listening']), runId=ids['listen'], logLines=report['logLines'], resources=sample_listen)
    records=alive_records(); write('c-managed-identities.json',records)
    check('child and detached grandchild tracked', len([r for r in records if r['runId']==ids['tree']])>=3)
    footprint('three-services')
    smoke=spawn([APP,'--app-smoke',OUT/'c-app-smoke.txt'],'c-app-smoke'); check('real scene close reopen and quit',wait(smoke)==0 and 'same-runs=true' in (OUT/'c-app-smoke.txt').read_text())
    check('quitting native app preserves runs', {s['id']:s['currentRun']['id'] for s in status()['services']}==ids)
    shot('c-option-pending','--option',project_id+'/host','--option-value','0.0.0.0','--option-save','--option-close','--delay','1')
    p=api('GET','/projects/'+project_id)
    check('UI value saved without restart',service(status(),'listen')['currentRun']['id']==ids['listen'] and next(x for x in p['config']['params'] if x['key']=='host')['setBy']=='user')
    updated=cli('project','update',project_id,'--config',str(conf),'--if-revision',str(p['revision']),'--json')
    check('AI update preserves user value', 'host' in updated['keptUserValues'] and next(x for x in updated['config']['params'] if x['key']=='host')['value']=='0.0.0.0',kept=updated['keptUserValues'])
    shot('c-option-restarted','--perform','restart:'+project_id+'/listen','--select',project_id+'/listen','--tab','runs','--delay','3')
    newrun=service(status(),'listen')['currentRun']['id']; detail=api('GET','/runs/'+newrun)
    stats=cli('stats',project_id,'--json')
    check('restart uses new value and real all-interface port',newrun!=ids['listen'] and detail['params']['host']=='0.0.0.0' and '0.0.0.0' in detail['command'] and any(x['address']=='0.0.0.0' for x in stats['services']['listen']['listening']),runId=newrun,command=detail['command'])
    shot('c-delete-inline','--delete-option',project_id+'/host')
    shot('c-deleted-inline','--delete-option',project_id+'/host','--confirm-delete')
    p=api('GET','/projects/'+project_id)
    check('deleting referenced option writes current value',not any(x['key']=='host' for x in p['config']['params']) and p['config']['services'][0]['command'][2]=='0.0.0.0')
    shot('c-inline-starts','--perform','restart:'+project_id+'/listen','--delay','1')
    # UI stops a run created by CLI; CLI then confirms the same run ended and its identity vanished.
    before_stop=alive_records(); listen_records=[r for r in before_stop if r['runId']==service(status(),'listen')['currentRun']['id']]
    stopped=shot('c-ui-stop-cli-confirm','--perform','stop:'+project_id+'/listen','--select',project_id+'/listen','--tab','logs','--delay','2')
    view=status(); check('native stop visible to CLI and port cleared',service(view,'listen')['state']=='stopped' and service(view,'listen')['currentRun'] is None and 'listen' not in cli('stats',project_id,'--json')['services'])
    verify_gone(listen_records)
    starting=shot('c-ui-start','--perform','start:'+project_id+'/listen','--select',project_id+'/listen','--delay','1',asynchronous=True)
    deadline=time.monotonic()+15
    while 'status:' not in (OUT/'c-ui-start.log').read_text() and time.monotonic()<deadline: time.sleep(.01)
    same=cli('start',project_id,'--service','listen','--json')
    check('native start snapshot finished',wait(starting)==0)
    check('overlapping native and CLI starts share run',same['results'][0]['outcome'] in ['started','already-running'] and same['results'][0]['runId']==service(status(),'listen')['currentRun']['id'])
    shot('c-stop-timeout','--perform','stop:'+project_id+'/tree')
    check('stop timeout remains stopping',service(status(),'tree')['stopTimedOut'] is True)
    failed=shot('c-shutdown-failure','--shutdown-daemon')
    check('shutdown failure preserves daemon',api('GET','/daemon')['pid']==daemon['pid'] and service(status(),'tree')['currentRun'] is not None)
    tree_records=[r for r in records if r['runId']==ids['tree']]
    shot('c-force-stop','--perform','force-stop:'+project_id+'/tree')
    verify_gone(tree_records)
    # Start another tree with an 8s stop wait; stop arrives while restart is still waiting.
    patch_config(lambda c: c['services'][1].update(stopTimeoutSec=8))
    cli('start',project_id,'--service','tree','--json')
    old=service(status(),'tree')['currentRun']['id']
    pshot=shot('c-stop-during-restart','--before-actions-delay','2','--perform','stop:'+project_id+'/tree','--timeout','20',asynchronous=True)
    deadline=time.monotonic()+15
    while 'status:' not in (OUT/'c-stop-during-restart.log').read_text() and time.monotonic()<deadline: time.sleep(.1)
    restart=cli('restart',project_id,'--service','tree','--no-wait','--json')
    check('restart race snapshot finished',wait(pshot)==0)
    op=cli('operation',restart['id'],'--json')
    check('user stop cancels restart without replacement',op['state']=='cancelled' and service(status(),'tree')['currentRun']['id']==old,operation=op)
    cli('force-stop',project_id,'--service','tree','--json')
    cli('start',project_id,'--service','exit','--json')
    marker.write_text('exit\n')
    time.sleep(.2)
    failed_report=shot('c-self-exit','--select',project_id+'/exit','--tab','logs','--delay','1')
    check('self exit retains logs and badge',service(status(),'exit')['state']=='failed' and failed_report['logLines']>0 and failed_report['badge']==1)
    shot('c-notification-route','--notification-open',project_id+'/exit','--delay','1')
    # Keep existing client connected, then shut down daemon normally. Prior state must become stale.
    cli('stop',project_id,'--json')
    stale=shot('c-disconnected','--delay','6',asynchronous=True)
    time.sleep(2)
    cli('daemon','stop','--json')
    check('disconnect screenshot rendered',wait(stale)==0)
    disconnected=json.loads((OUT/'c-disconnected.json').read_text())
    check('disconnect is not live state',disconnected['status']!='connected',status=disconnected['status'])
    cli('daemon','start','--json')
    shot('c-remove-project','--remove-project',project_id)
    shot('c-removed-project','--remove-project',project_id,'--confirm-remove','--delay','1')
    check('remove preserves source files', (FIX/'keep-me.txt').exists() and not cli('project','list','--json'))
    verify_gone(records)
    check('v0.2 acceptance complete',True)


def cleanup():
    if owns_home and (HOME/'daemon.json').exists():
        try:
            projects=api('GET','/projects')
            for project in projects:
                for s in project['services']:
                    if s['currentRun']:
                        cli('force-stop',project['id'],'--service',s['id'],'--json')
            cli('daemon','stop','--json')
        except Exception as e:
            print('Isolated daemon cleanup requires attention: '+str(e),flush=True)
    for process, ident, log in owned:
        stop_owned(process)
        log.close()


def measure_only():
    global HOME, ENV, owns_home, checks
    checks = json.loads((OUT/'c-results.json').read_text())
    HOME = OUT/'perf'
    ENV = dict(os.environ, DEVPANEL_HOME=str(HOME), DEVPANEL_PORT='0')
    if HOME.exists(): raise RuntimeError('Performance home already exists')
    HOME.mkdir(mode=0o700); owns_home = True
    (FIX/'exit-now').unlink(missing_ok=True)
    cli('daemon','start','--json')
    footprint('idle')
    p=cli('project','register','--config',str(OUT/'acceptance-config.json'),'--json')['project']['id']
    cli('start',p,'--json')
    footprint('three-services')
    identities=[]
    for s in cli('status',p,'--json')['services']:
        for proc in api('GET','/runs/'+s['currentRun']['id'])['processes']:
            identities.append(dict(**proc, osIdentity=identity(proc['pid'])))
    cli('force-stop',p,'--json')
    verify_gone(identities)
    cli('project','remove',p,'--json')


def ui_cpu():
    global OUT, HOME, FIX, APP, ENV, owns_home
    phase = sys.argv[sys.argv.index('--ui-cpu') + 1]
    if phase not in ['before', 'after']: raise ValueError('phase must be before or after')
    base = ROOT / '.devpanel-dev/codex/ui-cpu'
    base.mkdir(parents=True, exist_ok=True)
    helper = base / 'activate.swift'
    helper.write_text('import AppKit\nlet pid = Int32(CommandLine.arguments[1])!\nNSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])\n')
    subprocess.run(['swiftc', str(helper), '-o', str(base / 'activate')], check=True)
    OUT = base / phase
    OUT.mkdir(parents=True, exist_ok=False)
    HOME = base / ('h-' + phase)
    HOME.mkdir(mode=0o700, exist_ok=False)
    owns_home = True
    FIX = base / 'fixtures'
    FIX.mkdir(exist_ok=True)
    APP = base / (phase + '-app/DevPanel.app/Contents/MacOS/DevPanel')
    ENV = dict(os.environ, DEVPANEL_HOME=str(HOME), DEVPANEL_PORT='0')
    cli('daemon', 'start', '--json')
    daemon_pid = json.loads((HOME / 'daemon.json').read_text())['pid']
    write('daemon-identity.json', dict(pid=daemon_pid, osIdentity=identity(daemon_pid)))
    projects = []
    for index, count in enumerate([3, 2]):
        root = FIX / ('project-' + str(index)); root.mkdir(exist_ok=True)
        config = dict(schemaVersion=1, name='CPU 项目 ' + str(index+1), root=str(root),
            services=[dict(id='s'+str(n), name='安静服务 '+str(n+1), cwd='.',
                command=[NODE, '-e', 'setInterval(()=>{},1000)']) for n in range(count)])
        path = OUT / ('config-' + str(index) + '.json'); path.write_text(json.dumps(config, ensure_ascii=False))
        projects.append(cli('project', 'register', '--config', str(path), '--json')['project']['id'])
    results = {}
    results['a'] = footprint('a', target=.5)
    for project in projects: cli('start', project, '--json')
    selected = projects[0] + '/s0'
    results['b'] = footprint('b', target=2)
    results['c'] = footprint('c', '--select', selected, '--tab', 'logs', target=3)
    results['d'] = footprint('d', '--bench-minimized', target=.3)
    results['f'] = footprint('f', '--bench-resource-popover', target=2)
    # Ten quiet services across the same two projects.
    for project in projects:
        data = api('GET', '/projects/' + project)
        config = data['config']
        for n in range(len(config['services']), 5):
            config['services'].append(dict(id='s'+str(n), name='安静服务 '+str(n+1), cwd='.',
                command=[NODE, '-e', 'setInterval(()=>{},1000)']))
        api('PUT', '/projects/'+project, dict(ifRevision=data['revision'], config=config))
        cli('start', project, '--json')
    results['e'] = footprint('e', target=results['b']['app']['cpuPercent'] + 1)
    for project in projects: cli('stop', project, '--json')
    data = api('GET', '/projects/' + projects[0]); config = data['config']
    config['services'][0]['command'] = [NODE, '-e', 'setInterval(()=>console.log("log fixture line"),50)']
    api('PUT', '/projects/'+projects[0], dict(ifRevision=data['revision'], config=config))
    cli('start', projects[0], '--service', 's0', '--json')
    results['g'] = footprint('g', '--select', selected, '--tab', 'logs')
    # Additional comparison screenshots, outside measurement intervals.
    shot('runs', '--select', selected, '--tab', 'runs', '--layout', 'detail', '--appearance', 'dark')
    shot('resources', '--tool-resources-details', '--layout', 'detail', '--appearance', 'dark')
    write('summary.json', results)


if __name__=='__main__':
    try:
        if '--ui-cpu' in sys.argv: ui_cpu()
        elif '--measure-only' in sys.argv: measure_only()
        else: run()
    finally:
        cleanup()
