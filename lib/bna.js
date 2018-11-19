let bna;
const fs = require("fs");
const resolver = require("resolve");
const async = require("async");
const path = require("path");
const _ = require("underscore");
const ast = require("./ast");
const wrench = require("wrench");
const util = require('util');
const log = require("lawg");
require("colors");

const acornjsx = require("acorn-jsx");
const acorn = require("acorn");

let Parser = acorn;
const ParserOptions = {
    ecmaVersion: 6,
    allowImportExportEverywhere: true,
    allowHashBang: true,
    allowReturnOutsideFunction: true,
    locations: false
};

const jsParse = src => {
    return Parser.parse(src, _.extend({}, ParserOptions, { locations: bna.locations }));
};


module.exports = (bna = {
    enableJsx() {
        Parser = acornjsx;
        return ParserOptions.plugins = { jsx: true };
    },

    quiet: false,
    locations: false, // where to ask parser to save line locations

    warn(msg) {
        if (!bna.quiet) { return log(msg.gray); }
    },

    _cache: {}, // dep.path => { dep object }

    /*
     * given path to js file (as returned by require.resolve), identify the node module that contains it, think of it
     * as reverse of require.resolve
     * returns
     *
     * @param file  : path to js file to identify
     * @returns  {
     *     "mname": "mylib",    # module name, as used by require
     *     "path"   : "node_modules/mylib/file.js",
     *     "mpath"  : "node_modules/mylib",             # the path of module that contains this file
     *     "package" : { package.json object if exists }
     *   }
     *   - "mpath" may point to a file in case of node_modules/mylib.js
     */
    identify(file) {
        const ret = {};
        // if file is a path location, then find module path containg file
        ret.mpath = /\/|\\/.test(file) ? bna.findModulePath(file) : file;
        if (!ret.mpath) ret.mpath = path.dirname(file); // no node module found, just use parent dir as mpath
        if (ret.mpath === file) {
            ret.mname = path.basename(ret.mpath).replace(/\.(js|node)$/i, '');
        } else {
            ret.mname = path.basename(ret.mpath);
            const packageJsonFile = path.join(ret.mpath, "package.json");
            if (fs.existsSync(packageJsonFile)) {
                ret.package = JSON.parse(fs.readFileSync(packageJsonFile));
            }
        }
        return ret;
    },

    findModulePath(fullpath) {
        if (!fullpath || (fullpath === "/")) { return undefined; }
        if (fs.existsSync(path.join(fullpath, "package.json"))) { return fullpath; }
        const parentpath = path.dirname(fullpath);
        const packageJsonFile = path.join(parentpath, "package.json");
        if (fs.existsSync(packageJsonFile)) {
            return parentpath;
        } else if (path.basename(parentpath) === "node_modules") {
            return fullpath;
            // remove identifying pure path/index.js as a module, module must contain package.json
            //    else if (['index.js', 'index.node'].indexOf(path.basename(fullpath).toLowerCase()) != -1 ) then return parentpath;
        } else { return bna.findModulePath(parentpath); }
    },

    mainFile(mpath) {
        let fpath;
        fpath;
        if (fs.existsSync(fpath = path.join(mpath, "package.json"))) {
            const pkg = JSON.parse(fs.readFileSync(fpath));
            if ("main" in pkg) { return path.resolve(mpath, pkg.main); }
        } else if (fs.existsSync(fpath = path.join(mpath, "index.js"))) {
            return fpath;
        } else if (fs.existsSync(fpath = path.join(mpath, "index.node"))) {
            return fpath;
        }
        return null;
    },

    /*
      Internal, collapse dependent files belong to same package
      assumes unit.requires is [ {node, unit} ....] when passed in (as returned by _parseFile)
      on output, unit.requires is [ unit, .... ],  the other non consequential members are stripped out
      the recursive tree data structure is preserved.
    */
    _collapsePackages(unit) {
        const memory = {}; // handle circular reference
        var doCollapse = function(unit) {
            let reqs;
            memory[unit.mpath] = true;
            const detail = _({}).extend(unit);
            if (detail.requires) {
                // first pass, find all requires that are not in the same module
                reqs = _(detail.requires).reduce(function(memo, { unit }) {
                    if (detail.mpath === unit.mpath) { // same package!
                        if (unit.requires !== undefined) {
                            memo = _(memo).concat((() => {
                                const result = [];
                                for ({ unit }
                                    of Array.from(unit.requires)) {
                                    result.push(unit);
                                }
                                return result;
                            })());
                        }
                    } else { memo.push(unit); }
                    return memo;
                }, []);
            }

            detail.requires = _(reqs).chain().map(function(unit) {
                if (memory[unit.mpath]) {
                    return unit;
                } else { return doCollapse(unit); }
            }).unique(unit => // remove duplicates
                unit.mpath
            ).value();
            return detail;
        };

        return doCollapse(unit);
    },
    /*
     * figures out module dependencies for you,
     *  how does it work?  by finding the main file for a package, then walk through ast of the file, find all requires
     *  to determine the external&local packages in its dependencies.
     *   * external : a required external and non-system node module
     *   * local    : the module exists locally (can be resolved via require.resolve)
     *
     * @param fpath          : path of main module file, should be what's returned by require.resolve('module')
     * @param cb(err, alldpes, externdeps, main)
     *  alldeps:  all dependencies, an object, value could be:
                  - string,  single version
                  - array of string, multiple versions
                  - null, key is either a built-in module, or a full path file (not a module main file)
        externdeps:  dependences that do not reside in fpath
        main :       the main detail for fpath
        warnings :   require resolve warnings
    */
    npmDependencies(fpath, cb) {
        try {
            let unit = bna._parseFile(null, fpath, bna._cache);
            const warnings = _((() => {
                const result = [];
                for (unit of Array.from(bna._flattenRequires(unit))) {
                    result.push(unit.warnings);
                }
                return result;
            })()).flatten();
            unit = bna._collapsePackages(unit);
            //log(JSON.stringify(unit,null, "  "));
            let dependencies = null;
            let externDeps = null;

            dependencies = _(unit.requires).reduce(function(memo, unit) {
                    if (unit.package) {
                        memo[unit.mname] = unit.package.version;
                    } else {
                        if (unit.isCore) {
                            memo[unit.fpath] = null; // required an individual file that's not a main file of a npm package
                        } else {
                            memo[unit.fpath] = null;
                        }
                        memo;
                    }
                    return memo;
                },

                {});

            externDeps = bna.externDeps(unit);
            //console.log(fpath, ", ", dependencies);
            return cb(null, dependencies, externDeps, unit, warnings);
        } catch (e) {
            return cb(e);
        }
    },


    /*
     *  Give a module, find all its dependencies that are NOT located in its local node_module path, useful
     *  for building the final app.

     *  Internal helper called by npmDependencies.
     *
    */
    externDeps(unit) {
        let ret = [];
        // find all depended modules not in root's path
        const isPathContained = function(path) {
            for (let i = 0; i < ret.length; i++) {
                const e = ret[i];
                if (path.indexOf(e.mpath) === 0) {
                    return true;
                }
            }
            return false;
        };

        const memory = {}; // handle circular reference
        var walk = function(unit) {
            memory[unit.mpath] = true;
            if (!unit.isCore && !isPathContained(unit.mpath)) {
                ret.push(unit);
            }
            if (unit.requires) {
                return unit.requires.forEach(function(unit) {
                    if (!memory[unit.mpath]) { return walk(unit); }
                });
            }
        };
        walk(unit);

        ret = _(ret).chain().map(unit => // extract wanted values
            ({
                'require': unit.mname,
                'mpath': unit.mpath,
                'version': unit.package ? unit.package.version : null
            })
        ).unique(unit => // remove duplicates
            unit.mpath
        ).value();
        return ret;
    },


    // npmDependencies/externDependModules on dir: basically recursively scan a dir for all .js file and find their
    // merged dependencies.  This is useful when you want to calculate all dependency for all files reside in a module
    // dir and some of these .js files are not required by the main module .js file
    dir: {
        // scan dir according npm's ignore rules, by using fstream-npm
        _scanDir(dir, iteratorCb, doneCb) {
            return async.waterfall([
                function(cb) {
                    const files = [];
                    const fnpm = require("fstream-npm");
                    return fnpm({
                        path: dir
                    }).on("child", c => files.push(c._path)).on('close', () => cb(null, files));
                },

                (files, cb) =>
                //files = _(files).map(function(f) { return path.join(dir, f)});
                async.each(files, (file, cb) =>
                    fs.stat(file, function(err, stat) {
                        if (stat.isDirectory() && (path.basename(file) !== 'node_modules')) {
                            return iteratorCb(file, true, cb);
                        } else if (path.extname(file) === ".js") {
                            return iteratorCb(file, false, cb);
                        } else { return cb(); }
                    }),
                    cb)
                // async.each complete
            ], doneCb);
        }, // waterfall done

        npmDependencies(dir, cb) {
            const alldeps = {};
            let allextdeps = [];
            let allwarnings = [];
            return bna.dir._scanDir(dir,
                function(file, isDir, cb) {
                    const f = isDir ? bna.dir.npmDependencies : bna.npmDependencies;
                    return f(file, function(err, deps, extdeps, main, warnings) {
                        _(alldeps).extend(deps);
                        allextdeps = _(allextdeps).concat(extdeps);
                        allwarnings = _(allwarnings).concat(warnings);
                        return cb(err);
                    });
                },
                function(err) {
                    const detail = bna.identify(dir);
                    delete alldeps[detail.mname];

                    allextdeps = _(allextdeps).chain()
                        .unique(d => d.mpath)
                        .filter(d => d.mpath.indexOf(dir) !== 0)
                        .value();

                    return cb(err, alldeps, allextdeps, { mpath: dir }, allwarnings);

                });
        }
    },

    /*
     * Make extern dependencies local by copying them to local node_modules folder
     * @param mpath     path to a dir or file (the file must be main entry point of module, i.e. returned by require.resolve
     * @param progressCb (msg),  copy in progress callback, if you want to print status
     * @param doneCb(err) completion callback
     *
     */
    copyExternDependModules(mpath, progressCb, doneCb) {
        return fs.stat(mpath, function(err, stat) {
            if (err) { return cb(err); }
            const f = stat.isDirectory() ? bna.dir.npmDependencies : bna.npmDependencies;
            return f(mpath, function(err, __d, extDependencies, main) {

                const targetPath = path.join(main.mpath, "node_modules");
                if (!fs.existsSync(targetPath)) {
                    wrench.mkdirSyncRecursive(targetPath);
                }
                return async.eachSeries(
                    extDependencies,
                    function(d, cb) {
                        const targetModulePath = path.join(targetPath, path.basename(d.mpath));
                        progressCb(util.format("Copying '%s': %s => %s",
                            d.mname,
                            path.relative(process.cwd(), d.mpath),
                            path.relative(process.cwd(), targetModulePath)));
                        if (!fs.existsSync(targetModulePath)) { fs.mkdirSync(targetModulePath); }
                        return wrench.copyDirRecursive(d.mpath, targetModulePath, cb);
                    },

                    doneCb
                );
            });
        });
    },

    /*
     * Merge the module dependency calculated by bna.npmDependencies or bna.dir.npmDependencies into the package.json
     * of main module. The merge rules are:
     * 1. if not exist yet, dependency is added
     * 2. otherwise, do not modify current package.json
          a. however if detected dependency exits in current package.json, then check if versions are compatible,
     *
     * @param mpath     path to a dir or file (the file must be main entry point of module, i.e. returned by require.resolve
     * @param cb(err, [] )  [] is removed packages
    */
    writePackageJson(mpath, cb) {
        const semver = require("semver");
        return fs.stat(mpath, function(err, stat) {
            if (err) { return cb(err); }
            const f = stat.isDirectory() ? bna.dir.npmDependencies : bna.npmDependencies;
            return f(mpath, function(err, deps) {
                if (err) { return cb(err); }
                if (stat.isFile()) {
                    ({ mpath } = bna.identify(mpath));
                }
                const pkgJsonFile = path.join(mpath, "package.json");
                let pkgJson = {};
                if (fs.existsSync(pkgJsonFile)) {
                    pkgJson = JSON.parse(fs.readFileSync(pkgJsonFile, "utf8"));
                }
                const oldDep = pkgJson.dependencies || {};
                const newdep = {};
                const errList = [];
                // merge into oldDep
                _(deps).each(function(version, name) {
                    if (version === null) {
                        //errList.push(util.format("%s is not versioned!",name));
                        return;
                    } else if (!(name in oldDep)) {
                        return newdep[name] = version;
                    } else { // use semver to check
                        const oldVer = oldDep[name];
                        if (/:\/\//.test(oldVer)) { // test for url pattern
                            log(util.format("Package %s is ignored due to non-semver %s", name, oldVer));
                            delete oldDep[name];
                            return newdep[name] = oldVer; // keep old value
                        } else if (!semver.satisfies(version, oldVer)) {
                            return errList.push(util.format("%s: actual version %s does not satisfy package.json's version %s", name, version, oldVer));
                        } else {
                            delete oldDep[name];
                            return newdep[name] = oldVer;
                        }
                    }
                });
                if (errList.length > 0) {
                    return cb(new Error(errList.join("\n")));
                } else {
                    pkgJson.dependencies = newdep;
                    return fs.writeFile(pkgJsonFile, JSON.stringify(pkgJson, null, 2), "utf8", err => cb(err, _(oldDep).keys()));
                }
            });
        });
    },


    // get all dependencies including self, deduplicated, and flattened
    _flattenRequires(unit) {
        var getreqs = function(unit, cache) { // use cache to handle circular require
            let units;
            if (unit.fpath in cache) { return cache[unit.fpath]; }
            cache[unit.fpath] = (units = []);
            const deps = _((() => {
                const result = [];
                for (let { node, unit: child_unit }
                    of Array.from(unit.requires)) {
                    result.push(getreqs(child_unit, cache));
                }
                return result;
            })()).flatten();
            for (let d of Array.from(deps)) { units.push(d); }
            units.push(unit);
            return units;
        };
        const units = getreqs(unit, {}); // flatten
        return _(units).unique(unit => unit.fpath);
    }, // de-dup


    // filepath:  path to the file to fuse
    // outdir : the output dir, needed for sourcemap concat
    // moduleName: name of main module, a global var of moduleName is created (for browser), set '' to not create
    // opts: { aslib: true|false, prependCode: "var x = require('x');", generateSm: true|false }
    // return [content, binaryUnits, warnings, units]
    // content: "fused" source code
    // binaryUnits: the binary units (.node files)
    // warnings: array of warnings: requires that are not processed
    // units: array of all file units
    _fuse(filepath, outdir, moduleName, opts) {
        if (opts == null) { opts = {}; } // aslib: true|false
        filepath = path.resolve(filepath);
        // fakeCode: internal param, used by fuseDirTo only.  When fusing a dir, need to create a fake
        // file that requires all fused modules...
        let unit = bna._parseFile(null, filepath, {}, true, opts.fakeCode, opts.ignoreMods);

        if (!outdir) { outdir = path.dirname(filepath); }
        // get all dependencies including self (filepath), deduplicated
        const units = bna._flattenRequires(unit);
        const warnings = _((() => {
            const result = [];
            for (unit of Array.from(units)) {
                result.push(unit.warnings);
            }
            return result;
        })()).flatten();

        const ret = (require("./fuse")).generate({
            baseDir: outdir,
            moduleName,
            units,
            asLib: opts.aslib,
            generateSm: opts.generateSm,
            prependCode: opts.prependCode || ''
        });
        ret.push(...Array.from([warnings, units] || []));
        return ret;
    },

    generateModuleName(fullpath) {
        let ret = path.basename(fullpath).replace(/\..*$/, '');
        if (ret.toLowerCase() === "index") { ret = path.basename(path.dirname(fullpath)); }
        return ret;
    },

    // helper to turn warnings returned by "fuse" into human readable messages
    prettyWarnings(warnings) {
        let reason;
        const msgs = {
            'nonconst': 'require dynamic modules: ',
            'resolve': 'require ignored because parameter can not be resolved',
            'dynamicResolveError': 'dynamic required module resolve error'
        };
        const pe = function(e) { if (e) { return `, ${e}`; } else { return ''; } };
        const warnings1 = ((() => {
            let error, node;
            const result = [];
            for ({ node, reason, error }
                of Array.from(warnings)) {
                if (reason !== 'nonconst') {
                    result.push(`${path.relative('.',node.loc.file)}:${node.loc.line}: ${msgs[reason]}${pe(error)}`);
                }
            }
            return result;
        })());
        const lines = locs => ((Array.from(locs).map((l) => l.line)).join(','));
        const warnings2 = ((() => {
            let locs, modules;
            const result1 = [];
            for ({ reason, locs, modules }
                of Array.from(warnings)) {
                if (reason === 'nonconst') {
                    result1.push(`${path.relative('.',locs[0].file)}:${lines(locs)}: ${msgs[reason]}${modules.join(',')}`);
                }
            }
            return result1;
        })());
        return warnings1.concat(warnings2);
    },

    // fuse filepath, write output to directory dstdir, using opts
    // opts: aslib: true|false, generateSm: true|false
    fuseTo(filepath, dstdir, opts) {
        if (opts == null) { opts = {}; }
        filepath = path.resolve(filepath);

        const moduleName = bna.generateModuleName(opts.dstfile || filepath);
        const [content, binaryunits, sourcemap, warnings, units] = Array.from(bna._fuse(filepath, dstdir, moduleName, opts));
        for (let warning of Array.from(bna.prettyWarnings(warnings))) { bna.warn(warning); }
        wrench.mkdirSyncRecursive(dstdir);
        const dstfile = path.resolve(dstdir, opts.dstfile || (path.basename(filepath, ".js") + ".fused.js"));
        const smFile = dstfile + ".map";

        log(`Generating ${path.relative('.', dstfile)}`);
        fs.writeFileSync(dstfile, content);
        if (sourcemap) {
            log(`Generating ${path.relative('.', smFile)}`);
            sourcemap.file = path.basename(dstfile);
            fs.writeFileSync(smFile, JSON.stringify(sourcemap, null, 2));
            fs.appendFileSync(dstfile, `\n//# sourceMappingURL=${path.basename(smFile)}`);
        }

        // copy binary units
        for (let bunit of Array.from(binaryunits)) {
            const dfile = path.resolve(dstdir, bunit.binName);
            if (fs.existsSync(dfile)) {
                bna.warn(`Skipped copying ${dfile}, already exists.`);
            } else {
                wrench.mkdirSyncRecursive(path.dirname(dfile));
                fs.createReadStream(bunit.fpath).pipe(fs.createWriteStream(dfile));
            }
        }
        return units;
    },

    // read  dirpath non-recursively, fuse all found js or modules into dstdir
    // opts: aslib
    fuseDirTo(dirpath, dstdir, opts, cb) {
        let fakeCode = "";
        var scandir = function(curdir, cb) {
            const files = [];
            const fnpm = require("fstream-npm"); // for .npmignore
            return fnpm({
                path: curdir
            }).on("child", c => files.push(c._path)).on('close', function() {
                let fpath;
                const recursePaths = [];
                for (let name of Array.from(files)) {
                    fpath = path.resolve(curdir, name);
                    const stat = fs.statSync(fpath);
                    if (stat.isFile()) {
                        const extname = (path.extname(name).toLowerCase());
                        if (name.toLowerCase() === "package.json") {
                            const pkg = JSON.parse(fs.readFileSync(fpath));
                            if (pkg.main) {
                                const mpath = path.resolve(path.dirname(fpath), pkg.main);
                                fakeCode += `require('./${path.relative(dirpath, mpath)}')\n`;
                            }
                        } else if ((extname === ".js") || (extname === ".node")) {
                            fakeCode += `require('./${path.relative(dirpath, fpath)}')\n`;
                        }
                    } else if (stat.isDirectory()) {
                        if (fs.existsSync(path.resolve(fpath, "package.json")) ||
                            fs.existsSync(path.resolve(fpath, "index.js")) ||
                            fs.existsSync(path.resolve(fpath, "index.node"))) {
                            fakeCode += `require('./${path.relative(dirpath, fpath)}')\n`;
                        } else {
                            recursePaths.push(fpath);
                        }
                    }
                }
                return async.eachSeries(recursePaths,
                    (path, cb) => scandir(fpath, cb),
                    cb
                );
            });
        };

        return scandir(dirpath, function() {
            let units;
            if (!fakeCode) {
                log("No files detected");
            } else {
                opts.fakeCode = fakeCode;
                units = bna.fuseTo(path.resolve(dirpath, "lib.js"), dstdir, opts);
            }
            if (cb) { return cb(units); }
        });
    },

    // filepath: file to analyze dependency for
    // returns: [dependency, warnings]
    // dependency is an object, key: package name, val: version
    // warnings is an array of string
    fileDep(filepath) {
        filepath = path.resolve(filepath);
        let unit = bna._parseFile(null, filepath, {});
        var getreqs = function(unit, cache) {
            let units;
            if (unit.fpath in cache) { return cache[unit.fpath]; }
            cache[unit.fpath] = (units = []);
            units = _(units).concat(
                _((() => {
                    const result = [];
                    for (let { node, unit: child_unit }
                        of Array.from(unit.requires)) {
                        result.push(getreqs(child_unit, cache));
                    }
                    return result;
                })())
                .flatten());
            units.push(unit);
            return units;
        };

        // get all dependencies including self (filepath), deduplicated
        let units = getreqs(unit, {});
        units = _(units).unique(unit => unit.fpath);
        const warnings = _((() => {
            const result = [];
            for (unit of Array.from(units)) {
                result.push(unit.warnings);
            }
            return result;
        })()).flatten();
        const ret = {};
        for (let u of Array.from(units)) {
            if (u.package) {
                ret[u.package.name] = u.package.version;
            }
        }
        return [ret, warnings];
    },

    /*
     * helper: parse source code, recursively analyze require in code, return results in a nested tree structure
     * filepath: must be absolute path
     */
    _parseFile(requireName, filepath, cache, ifStoreSrc, fakeCode, coreModules) {
        let code, e;
        if (filepath in cache) { return cache[filepath]; }
        const isCore = (coreModules && (Array.from(coreModules).includes(requireName))) || !/[\\\/]/.test(filepath);
        const isBinary = /\.node$/i.test(filepath);
        const unit = {
            isCore, // built-in nodejs modules
            isBinary, // binary modules, ".node" extension
            fpath: isCore ? requireName : filepath, // the file path
            mpath: '', // the path of module that contains this file
            mname: '', // the module name
            src: "",
            requires: [], // array of dependencies, each element is {node, unit}
            // node is the parded ast tree node
            // unit is another unit
            warnings: [],
            // if set, then this file is the "main" file of a node module, as defined by nodejs
            package: undefined,
        };
        cache[filepath] = unit;
        if (isCore || isBinary) { return unit; }
        if (path.extname(filepath).toLowerCase() === ".json") {
            if (ifStoreSrc) { unit.src = fs.readFileSync(filepath).toString(); }
            return unit;
        }

        // determine if parameter filepath itself represents a module, if so, mark the module by setting the
        // package member
        (function() {
            const detail = bna.identify(filepath);

            unit.mname = detail.mname;
            unit.mpath = detail.mpath;
            unit._detailPackage = detail.package;
            const mainfiles = [path.join(detail.mpath, "index.js"), path.join(detail.mpath, "index.node")];
            if (detail.package) {
                detail.package.name = detail.mname; // ensure correct package name
                if (detail.package.main) {
                    const main = path.resolve(detail.mpath, detail.package.main);
                    mainfiles.push(main);
                    // append .js .node variations as well
                    if (path.extname(main) === '') { mainfiles.push(...Array.from([`${main}.js`, `${main}.node`] || [])); }
                }
            }
            if (Array.from(mainfiles).includes(unit.fpath)) {
                return unit.package = detail.package || { name: detail.mname, version: 'x' }; // construct default package if no package.json
            }
        })();

        // do first pass without parsing location info (makes parsing 3x slower), if bad require is detected,
        // then we do another pass with location info, for user-friendly warnings
        try {
            let src;
            if (fakeCode) {
                src = fakeCode;
            } else { src = fs.readFileSync(filepath).toString().replace(/^#![^\n]*\n/, ''); } // remove shell script marker

            if (ifStoreSrc) { unit.src = src; }
            code = jsParse(src);
        } catch (error) {
            e = error;
            log((`Ignoring ${filepath}, failed to parse due to: ${e}`));
            return unit;
        }
        // 1st pass, traverse ast tree, resolve all const-string requires if possible
        const dynLocs = []; // store dynamic require locations
        ast.traverse(code, [ast.isRequire], function(node) {
            if (!node.loc) {
                node.loc = { file: filepath, line: '?' };
            } else {
                node.loc.file = filepath;
                node.loc.line = node.loc.start.line;
            }
            const arg = node.arguments[0];
            if (arg && (arg.type === 'Literal')) { // require a string
                let fullpath;
                const modulename = arg.value;

                e = undefined;
                try {
                    fullpath = resolver.sync(modulename, {
                        extensions: ['.js', '.node', '.json'],
                        basedir: path.dirname(filepath)
                    });
                } catch (error1) {
                    e = error1;
                    unit.warnings.push({
                        node,
                        reason: "resolve"
                    });
                }

                if (!e) {
                    const runit = bna._parseFile(modulename, fullpath, cache, ifStoreSrc, null, coreModules);
                    return unit.requires.push({
                        name: modulename,
                        node,
                        unit: runit
                    });
                }
            } else {
                return dynLocs.push(node.loc);
            }
        });

        // resolving dynamic require trick: evaluate js once, record all required modules....
        if (dynLocs.length > 0) {
            (() => {
                let dynamicModules = bna.detectDynamicRequires(unit);
                // filter out already required string modules, and nulls
                dynamicModules = (Array.from(dynamicModules).filter((m) => m && !_(unit.requires).find(e => e.name === m)).map((m) => m));

                for (let modulename of Array.from(dynamicModules)) {
                    // filter out required modules that are already parsed
                    var node;
                    e = undefined;
                    let fullpath = ''; // catch block needs this too
                    try {
                        fullpath = resolver.sync(modulename, {
                            extensions: ['.js', '.node', '.json'],
                            basedir: path.dirname(filepath)
                        });
                        // only if resolved ok
                        node = { loc: { file: fullpath, line: '?' } }; //
                        const runit = bna._parseFile(modulename, fullpath, cache, ifStoreSrc, null, coreModules);
                        unit.requires.push({
                            name: modulename,
                            node,
                            unit: runit
                        });
                    } catch (error1) {
                        e = error1;
                        unit.warnings.push({
                            node: { loc: { file: filepath, line: '?' } },
                            reason: "dynamicResolveError",
                            error: e
                        });
                    }
                }

                return unit.warnings.push({
                    locs: dynLocs,
                    modules: dynamicModules,
                    reason: "nonconst"
                });
            })();
        }

        return unit;
    },


    // the trick to detect dynamicRequire, is to run the code with a spy 'require' which captures
    // there parameters....  this works in 90%+ scenarios
    detectDynamicRequires(unit) {
        const src = `\
var _sysreq = require;
(function() {
var dmodules = []
var require = function(module) {
  dmodules.push(module)
  return _sysreq(module)
};
${unit.src}
module.exports = dmodules;
})()\
`;
        const tmpfile = unit.fpath + ".bna.js";
        fs.writeFileSync(tmpfile, src);
        let dmodules = [];
        try {
            const _r = require; // prevent warning when fusing bna itself
            return dmodules = _.unique(_r(tmpfile));
        } catch (e) {
            return unit.warnings.push({
                node: { loc: { file: unit.fpath, line: '?' } },
                reason: 'dynamicResolveError',
                error: e
            });
        } finally {
            delete require.cache[tmpfile];
            fs.unlinkSync(tmpfile);
            return dmodules;
        }
    }
});