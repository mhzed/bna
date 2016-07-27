// Generated by CoffeeScript 1.10.0
(function() {
  var _, argv, bna, callFuseThrottleSec, ddir, deps, dofuse, dstfile, fpath, fs, isDir, k, mfile, optimist, path, resolver, targetPath, v;

  optimist = require('optimist').usage('Build modules and dependencies for app in the current dir.\nUsage: -b -p -c -f file -o out/').boolean(['b', 'p', 'c', 'q', 'w', 'l', 'v', 'jsx']).alias('b', 'build').alias('p', 'packagejson').alias('c', 'copy').alias('f', 'fuse').alias('q', 'quiet').alias('l', 'line').alias('v', 'version').string("fuselib").string('f').string("o").describe("v", "print version").describe('b', 'build app, same as -p -c together').describe('p', 'write module dependencies to package.json').describe('c', 'copy depended external modules to local node_modules dir').describe('f', 'generate a single executable js file, see doc.').describe('jsx', 'enable react jsx file support').describe('fuselib', 'fuse to a file that exports all dependant modules.').describe("o", 'specify output file or dir for fuse. Optional, default is .').describe("q", 'quite mode. No warnings').describe('w', 'watch file: fuse on change').describe('l', 'print warnings with line number');

  argv = optimist.argv;

  bna = require("../lib/bna");

  fs = require("fs");

  path = require("path");

  _ = require("underscore");

  if (argv.v) {
    console.log(require("../package.json").version);
    return;
  }

  if (argv.quiet) {
    bna.quiet = true;
  }

  if (argv.line) {
    bna.locations = true;
  }

  if (argv.jsx) {
    bna.enableJsx();
  }

  if (!(argv.b || argv.p || argv.c || argv.f || argv.fuselib)) {
    targetPath = argv._[0];
    if (!targetPath) {
      console.log(optimist.help());
      return;
    } else {
      targetPath = path.resolve(targetPath);
    }
    if (targetPath && fs.existsSync(targetPath)) {
      if (fs.lstatSync(targetPath).isDirectory()) {
        console.log("Analyzing directory...");
        bna.dir.npmDependencies(targetPath, function(err, deps, externDeps) {
          if (err) {
            return console.log(err);
          } else {
            console.log("Module dependencies are:");
            console.log(deps);
            if (externDeps) {
              console.log("Extern modules (node_modules located outside of current dir):");
              return console.log(externDeps);
            }
          }
        });
      } else {
        console.log("Analyzing file...");
        deps = (function() {
          var ref, results;
          ref = bna.fileDep(targetPath)[0];
          results = [];
          for (k in ref) {
            v = ref[k];
            results.push(k + "@" + v);
          }
          return results;
        })();
        console.log("Dependencies are:");
        console.log(deps.sort());
      }
    }
  } else if (argv.p) {
    bna.writePackageJson(process.cwd(), function(err, removedPackages) {
      if (err) {
        return console.log(err.stack);
      } else {
        if (removedPackages.length) {
          console.log("Removed unused packages: " + removedPackages);
        }
        return console.log("package.json dependencies updated");
      }
    });
  } else if (argv.c) {
    bna.copyExternDependModules(process.cwd(), function(msg) {
      return console.log(msg);
    }, function(err) {
      if (err) {
        return console.log(err.stack);
      } else {
        return console.log("copying finished");
      }
    });
  } else if (argv.b) {
    bna.writePackageJson(process.cwd(), function(err, removedPackages) {
      if (err) {
        return console.log(err.stack);
      } else {
        if (removedPackages.length) {
          return console.log("Removd unused packages: " + removedPackages);
        } else {
          console.log("package.json dependencies updated");
          return bna.copyExternDependModules(process.cwd(), function(msg) {
            return console.log(msg);
          }, function(err) {
            if (err) {
              return console.log(err.stack);
            } else {
              return console.log("copying finished");
            }
          });
        }
      }
    });
  } else if (argv.f || argv.fuselib) {
    resolver = require("resolve");
    ddir = ".";
    if (argv.f === true || argv.fuselib === true) {
      fpath = path.resolve(".");
    } else {
      fpath = path.resolve(argv.f || argv.fuselib);
    }
    if (fs.statSync(fpath).isDirectory()) {
      mfile = bna.mainFile(fpath);
      if ((argv.fuselib != null) && !mfile) {

      } else {
        fpath = mfile;
      }
    }
    if (!fpath) {
      console.log("Nothing to fuse, are you in a module folder?  See help below\n");
      console.log(optimist.help());
      process.exit(1);
    }
    console.log("Fusing file " + (path.relative('.', fpath)));
    if (argv.o) {
      dstfile = null;
      ddir = path.resolve(argv.o);
      if (path.extname(ddir).toLowerCase() === ".js") {
        dstfile = path.basename(ddir);
        ddir = path.dirname(ddir);
      }
    }
    isDir = fs.statSync(fpath).isDirectory();
    dofuse = (function(_this) {
      return function(cb) {
        if (isDir) {
          return bna.fuseDirTo(fpath, ddir, {
            aslib: argv.fuselib != null,
            dstfile: dstfile
          }, cb);
        } else {
          return process.nextTick(function() {
            var units;
            units = bna.fuseTo(fpath, ddir, {
              aslib: argv.fuselib != null,
              dstfile: dstfile
            });
            if (cb) {
              return cb(units);
            }
          });
        }
      };
    })(this);
    if (argv.w) {
      callFuseThrottleSec = typeof argv.w === 'string' ? parseInt(argv.w) : 2;
      (function(_this) {
        return (function() {
          var onChange, watch;
          onChange = (function() {
            var doChange;
            doChange = _.throttle(function() {
              return dofuse(function(units) {
                return watch(units);
              });
            }, callFuseThrottleSec * 1000, {
              leading: true
            });
            return function(e, fp) {
              console.log((path.relative('.', fp)) + " changed");
              return doChange();
            };
          })();
          watch = (function() {
            var watchers;
            watchers = {};
            return function(units) {
              var fp, i, len, newWatchers, unit, watcher;
              newWatchers = {};
              for (i = 0, len = units.length; i < len; i++) {
                unit = units[i];
                if (!unit.isCore) {
                  if (unit.fpath in watchers) {
                    newWatchers[unit.fpath] = watchers[unit.fpath];
                    delete watchers[unit.fpath];
                  } else {
                    (function(unit) {
                      if (!argv.quiet) {
                        console.log("Begin watching " + (path.relative('.', unit.fpath)));
                      }
                      return newWatchers[unit.fpath] = fs.watchFile(unit.fpath, function(e) {
                        return onChange(e, unit.fpath);
                      });
                    })(unit);
                  }
                }
              }
              for (fp in watchers) {
                watcher = watchers[fp];
                if (!argv.quiet) {
                  console.log("Stop watching  " + (path.relative('.', fp)));
                }
                fs.unwatchFile(fp);
              }
              return watchers = newWatchers;
            };
          })();
          return dofuse(watch);
        });
      })(this)();
    } else {
      dofuse();
    }
  }

}).call(this);

//# sourceMappingURL=bna.js.map
