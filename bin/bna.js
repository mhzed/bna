#!/usr/bin/env node

const optimist = require('optimist')
    .usage('Build modules and dependencies for app in the current dir.\nUsage: bna .')
    .boolean(['p','c', 'q', 'w', 'l', 'v','jsx', 'm'])
    .alias('p', 'packagejson')
    .alias('c', 'copy')
    .alias('f', 'fuse')
    .alias('q', 'quiet')
    .alias('l', 'line')
    .alias('v', 'version')
    .alias('m', 'map')
    .alias('i', 'ignore')
    .string("fuselib")
    .string('f')
    .string("o")
    .string("ignore")
    .describe("v", "print version")
    .describe('p', 'write module dependencies to package.json')
    .describe('c', 'copy depended external modules to local node_modules dir')
    .describe('f', 'generate a single executable js file, see doc.')
    .describe('m', 'generate source map for fuse option')
    .describe('jsx', 'enable react jsx file support')
    .describe('fuselib', 'fuse to a file that exports all dependant modules.')
    .describe("o", 'specify output file or dir for fuse. Optional, default is .')
    .describe("q", 'quite mode. No warnings')
    .describe('w', 'watch file: fuse on change')
    .describe('l', 'print warnings with line number')
    .describe("ignore", "specify ignored modules deliminated by comma,for fuse only");


const { argv } = optimist;
const bna = require("../lib/bna");
const fs = require("fs");
const path = require("path");
const _ = require("underscore");
const log = require('lawg');
if (argv.v) {
  console.log(require("../package.json").version);
  return;
}

if (argv.quiet) { bna.quiet = true; }
if (argv.line) { bna.locations = true; }
if (argv.jsx) { bna.enableJsx(); }

if (!(argv.p || argv.c || argv.f || argv.fuselib)) {

  let [targetPath] = Array.from(argv._);
  if (!targetPath) {
    console.log(optimist.help());
    return;
  } else {
    targetPath = path.resolve(targetPath);
  }
  if (targetPath && fs.existsSync(targetPath)) {
    if (fs.lstatSync(targetPath).isDirectory()) {
      console.log("Analyzing directory...");
      bna.dir.npmDependencies(targetPath, function(err, deps, externDeps, unit, warnings){
          if (err) { return console.log(err);
          } else {
            //bna.warn(msg) for msg in bna.prettyWarnings(warnings);
            let v;
            const unresolved = _.uniq(Array.from(warnings).filter((w) => w.reason === 'resolve').map((w) => w.node.arguments[0].value));
            if (unresolved.length > 0) {
              console.log("Unresolved requires:");
              console.log(unresolved);
            }

            console.log("Resolved module dependencies are:");

            const edeps = {};
            if (externDeps) {
              for (let {require,mpath,version} of Array.from(externDeps)) {
                edeps[`${require}@${version}`] = mpath;
              }
            }

            const pad = (str, n) => {
              if (n > str.length) { for (let i = 0, end = n-str.length, asc = 0 <= end; asc ? i <= end : i >= end; asc ? i++ : i--) { str+=' '; } }
              return str;
            };
            let npad = 0;
            for (var k in deps) { v = deps[k]; if (v !== null) { if ((k.length+v.length+2)>npad) { npad = k.length+v.length+2; } } }
            const sortedDeps = {};
            for (k of Array.from(_.keys(deps).sort())) { sortedDeps[k] = deps[k]; }
            deps = sortedDeps;

            return (() => {
              const result = [];
              for (k in deps) {
                v = deps[k];
                let item;
                if (v === null) {
                  if (!/[\/\\]/.test(k)) {  // do not print orphane files... they are just noises
                    item = console.log(`  ${k}`);
                  }
                } else {
                  const name = `${k}@${v}`;
                  const extdep = edeps[name];
                  const more = (extdep) ? `(${extdep})` : "";
                  item = console.log(`  ${pad(name,npad)}${more}`);
                }
                result.push(item);
              }
              return result;
            })();
          }
      });
    } else {
      console.log("Analyzing file...");
      const deps = ((() => {
        const result = [];
        const object = bna.fileDep(targetPath)[0];
        for (let k in object) {
          const v = object[k];
          result.push(`${k}@${v}`);
        }
        return result;
      })());
      console.log("Dependencies are:");
      console.log(deps.sort());
    }
  }
} else if (argv.p) {
  bna.writePackageJson(process.cwd(), function(err, removedPackages){
    if (err) { return console.log(err.stack);
    } else {
      if (removedPackages.length) { console.log(`Removed unused packages: ${removedPackages}`); }
      return console.log("package.json dependencies updated");
    }
  });
} else if (argv.c) {
  let copied = false;
  bna.copyExternDependModules(process.cwd(), function(msg){
    console.log(msg);
    return copied = true;
  }
  , function(err){
    if (err) { return console.log(err.stack);
    } else { return console.log(copied ? "copying finished" : "nothing to copy"); }
  });
} else if (argv.f || argv.fuselib) {
  let dstfile, fpath;
  const resolver    = require("resolve");
  let ddir = ".";
  if ((argv.f === true) || (argv.fuselib === true)) {
    fpath = path.resolve(".");
  } else {
    fpath = path.resolve(argv.f || argv.fuselib);
  }

  if (fs.statSync(fpath).isDirectory()) {
    const mfile = bna.mainFile(fpath);
    if ((argv.fuselib != null) && !mfile) { then; // leave fpath, fuselib works on a non-module directory
    } else { fpath = mfile; }    // fuse the main file
  }

  if (!fpath) {
    console.log("Nothing to fuse, are you in a project folder with package.json?");
    process.exit(1);
  }

  console.log(`Fusing file ${path.relative('.',fpath)}`);

  if (argv.o) {
    dstfile = null;
    ddir = path.resolve(argv.o);
    if (path.extname(ddir).toLowerCase() === ".js") {
      dstfile = path.basename(ddir);
      ddir = path.dirname(ddir);
    }
  }

  const isDir = fs.statSync(fpath).isDirectory();
  const ignoreMods = argv.ignore ? argv.ignore.split(',') : [];
  const dofuse = cb=> {
    if (isDir) {
      return bna.fuseDirTo(fpath, ddir, {aslib: (argv.fuselib != null), dstfile, generateSm: argv.m, ignoreMods }, cb);
    } else {
      return process.nextTick(()=> {
        const units = bna.fuseTo(fpath, ddir, {aslib: (argv.fuselib != null), dstfile, generateSm: argv.m, ignoreMods});
        if (cb) { return cb(units); }
      });
    }
  };


  if (argv.w) {
    // in case of spurious events, call fuse with 1 second delay/throttle
    const callFuseThrottleSec = typeof argv.w === 'string' ? parseInt(argv.w) : 2;
    (()=> {  // create stack
      const onChange = (()=> {
        const doChange = _.throttle( () => {
          return dofuse(units=> watch(units));
        }
        , callFuseThrottleSec * 1000, {leading: true});   // call fuse throttled
        return (e, fp)=> {         // the change function
          console.log(`${path.relative('.', fp)} changed`);
          return doChange();
        };
      })();

      var watch = (()=> {  // file watchers are installed dynamically
        let watchers = {};
        return units=> {
          const newWatchers = {};
          for (let unit of Array.from(units)) {
            if (!unit.isCore) {
              if (unit.fpath in watchers) {
                newWatchers[unit.fpath] = watchers[unit.fpath];
                delete watchers[unit.fpath];
              } else { (unit=> {
                if (!argv.quiet) { console.log(`Begin watching ${path.relative('.', unit.fpath)}`); }
                //newWatchers[unit.fpath] = (fs.watch unit.fpath, (e)=> onChange(e, unit.fpath))
                return newWatchers[unit.fpath] = (fs.watchFile(unit.fpath, e=> onChange(e, unit.fpath)));
              })(unit); }
            }
          }
          for (let fp in watchers) {
            const watcher = watchers[fp];
            if (!argv.quiet) { console.log(`Stop watching  ${path.relative('.', fp)}`); }
            //watcher.close()
            fs.unwatchFile(fp);
          }
          return watchers = newWatchers;
        };
      })();

      // the initial fuse, then start watching!
      return dofuse(watch);
    })();
  } else {
    dofuse();
  }
}
