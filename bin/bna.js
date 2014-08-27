#!/usr/bin/env node
(function() {
  var argv, bna, ddir, dstfile, fpath, fs, optimist, path, resolver;

  optimist = require('optimist').usage('Build modules and dependencies for app in current dir.\nUsage: -b -p -c -f file -o out/').boolean(['b', 'p', 'c', 'q']).alias('b', 'build').alias('p', 'packagejson').alias('c', 'copy').alias('f', 'fuse').alias('q', 'quiet').string("fuselib").string('f').string("o").describe('b', 'build app, same as -p -c together').describe('p', 'write module dependencies to package.json').describe('c', 'copy depended external modules to local node_modules dir').describe('f', 'generate a single executable js file, see doc.').describe('fuselib', 'fuse to a library to export modules, see doc.').describe("o", 'place fused files in this dir. Optional, default is ./').describe("q", 'quite mode. No warnings');

  argv = optimist.argv;

  bna = require("../lib/bna");

  fs = require("fs");

  path = require("path");

  if (!(argv.b || argv.p || argv.c || argv.f || argv.fuselib)) {
    console.log(optimist.help());
    if (fs.existsSync(path.join(process.cwd(), "package.json"))) {
      bna.dir.npmDependencies(process.cwd(), function(err, deps) {
        if (err) {
          console.log(err);
        } else {
          console.log("Module dependencies are:");
          console.log(deps);
        }
        return bna.dir.externDependModules(process.cwd(), function(err, deps) {
          if (err) {
            return console.log(err);
          } else {
            console.log("Extern modules (node_modules located outside of current dir):");
            return console.log(deps.slice(1));
          }
        });
      });
    }
  }

  if (argv.quiet) {
    bna.quiet = true;
  }

  if (argv.p) {
    bna.writePackageJson(process.cwd(), function(err, removedPackages) {
      if (err) {
        return console.log(err.stack);
      } else {
        if (removedPackages.length) {
          console.log("Removd unused packages: " + removedPackages);
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
      fpath = bna.mainFile(path.resolve("."));
      if (!fpath) {
        console.log("Nothing to fuse, are you in a module folder?  See help below\n");
        console.log(optimist.help());
        process.exit(1);
      }
      console.log("Fusing detected file " + (path.relative('.', fpath)));
    } else {
      fpath = path.resolve(argv.f || argv.fuselib);
    }
    if (argv.o) {
      dstfile = null;
      ddir = path.resolve(argv.o);
      if (path.extname(ddir).toLowerCase() === ".js") {
        dstfile = path.basename(ddir);
        ddir = path.dirname(ddir);
      }
    }
    if ((argv.fuselib != null) && fs.statSync(fpath).isDirectory()) {
      bna.fuseDirTo(fpath, ddir, {
        verbose: true,
        aslib: true,
        dstfile: dstfile
      });
    } else {
      bna.fuseTo(fpath, ddir, {
        verbose: true,
        aslib: argv.fuselib != null,
        dstfile: dstfile
      });
    }
    console.log("Finished");
  }

}).call(this);

/*
//@ sourceMappingURL=bna.map
*/
