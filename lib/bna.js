var detective   = require("detective");
var fs          = require("fs");
var resolver    = require("resolve");
var async       = require("async");
var path        = require("path");
var _           = require("under_score");


var bna = {
    _cache : {},    // dep.path => { dep object }

    /**
     * given path to js file (as returned by require.resolve), identify the node module that contains it, think of it
     * as reverse of require.resolve
     * returns
     *
     * @param file  : path to js file to identify
     * @returns  {
     *    "require": "mylib"
     *     "path"   : "node_modules/mylib/file.js",
     *     "mpath"  : "node_modules/mylib",
     *     "package" : { package.json object if exists }
     *   }
     *   - "mpath" may point to a file in case of node_modules/mylib.js
     */
    identify : function(file) {
        var ret = {
            "path"      : file,
            isSysModule : function() { return this.path == this.require; }  // if a system module like 'path' or 'fs'
        };
        function findModulePath(file) {
            if (!file || file == "/") return undefined;
            if (fs.existsSync(path.join(file, "package.json"))) return file;
            var parentpath = path.dirname(file);
            var packageJsonFile = path.join(parentpath, "package.json");
            if (fs.existsSync(packageJsonFile)) return parentpath;
            else if (path.basename(parentpath) == "node_modules") return file;
            else if (path.basename(file) in ['index.js', 'index.node']) return parentpath;
            else return findModulePath(parentpath);
        }
        ret.mpath = /\/|\\/.test(file)? findModulePath(file) : file;
        if (ret.mpath == file) {    // in case of node_modules/mylib.js
            ret.require = path.basename(ret.mpath).replace(/\.(js|node)$/i, '');
        } else {
            ret.require = path.basename(ret.mpath);
            var packageJsonFile = path.join(ret.mpath, "package.json");
            if (fs.existsSync(packageJsonFile)) {
                ret.package = JSON.parse(fs.readFileSync(packageJsonFile));
            }
        }
        return ret;
    },

    /**
     * async resolve all dependencies of file,
     * because nodejs supports circular require, returned data may contain circular reference, so when you recursively
     * walk the tree, make sure you handle the circular reference, see "_collapsePackages" for example.
     *
     * @param file          : path to the js file
     * @param level         : recursively resolve up to this many levels, optional, default infinite
     * @param cb            : where obj is what's returned by identify, with addition of 'deps' member
     *                        'deps'   :  what this file depends on, as an array of more 'identify' details
     */
    resolve : function(file, level, cb) {
        if (_(level).isFunction()) {    // handle optional level param
            cb = level;
            level = -1;
        }
        var detail = bna.identify(file);    // identify module details of file
        bna._cache[file] = detail;          // cache result early, for circular require

        if (level == 0 || detail.isSysModule() ) {   // stop at level 0, or at system module (contains no path divider)
            cb(null, detail);
            return;
        }
        // resolve dependencies
        async.waterfall([
            function(cb) {
                fs.readFile(file, 'utf8', cb);
            },
            function(fileContent, cb) {
                var requires = detective(fileContent);  // use detective to find all requires!
                async.map(      // resolve required items to actual file path
                    requires,
                    function(require_item, cb) {    // resolve required item from file's basedir
                        resolver(require_item, { basedir: path.dirname(path.resolve(file)) }, function(err, resolved) {
                            if (err) cb(null, null);    // suppress resolve error
                            else cb(null, resolved);
                        });
                    },
                    function(err, resolved_items) {
                        resolved_items = _.compact(resolved_items);
                        cb(err, resolved_items);
                    }
                );
            },
            function(depend_files, cb) {
                async.map(          // recursively resolve
                    depend_files,
                    function(resolved_file, cb) {
                        if (resolved_file in bna._cache)    // use cache
                            cb(null, bna._cache[resolved_file]);
                        else
                            bna.resolve(resolved_file, level - 1, cb);
                    },
                    function(err, details) {    // all resolved, insert into "deps" member of this detail
                        detail.deps = details;
                        cb(err, detail);
                    }
                )
            }
        ],
        cb  // (err, detail),  async completion
        );
    },

    /*
        Internal, collapse dependent files belong to same package
        parameter is not modified
     */
    _collapsePackages : function(paramDetail) {
        var memory = {};    // handle circular reference
        function doCollapse(paramDetail) {
            memory[paramDetail.mpath] = true;
            var detail = _({}).extend(paramDetail);
            if (!detail.deps) return detail;
            var deps = _(detail.deps).reduce(function(memo, dep) {
                if (detail.mpath == dep.mpath) {    // same package!
                    if (dep.deps !== undefined) _(memo).append(dep.deps);
                } else memo.push(dep);
                return memo;
            }, []);
            detail.deps = _(deps).chain().map(function(dep) {
                if (memory[dep.mpath]) return dep;
                else return doCollapse(dep);
            }).unique(function(dep) {   // remove duplicates
                return dep.mpath;
            }).value();
            return detail;
        }
        return doCollapse(paramDetail);
    },
    /**
     * figures out module dependencies for you,
     *  how does it work?  by finding the main file for a package, then walk through ast of the file, find all requires
     *  to determine the external&local packages in its dependencies.
     *   * external : a required external and non-system node module
     *   * local    : the module exists locally (can be resolved via require.resolve)
     *
     * @param file          : path of main module file, should be what's returned by require.resolve('module')
     * @param cb(err, dependencies), dependencies is what npm expects in package.json
     */
    npmDependencies : function(file, cb) {
        bna.resolve(require.resolve(file), function(err, detail) {
            if (err) return cb(err);
            detail = bna._collapsePackages(detail);
            var dependencies;
            if (!err) {
                dependencies = _(detail.deps).reduce(function(memo, depDetail) {
                    if (depDetail.package)
                        memo[depDetail.require] = depDetail.package.version;
                    else if (!depDetail.isSysModule())
                        memo[depDetail.require] = null;
                    return memo;
                },{});
            }
            cb(err, dependencies);
        })
    },

    /**
     *  Give a module, find all its dependencies that are NOT located in its local node_module path, useful
     *  for building the final app
     *
     * @param file     : path of main module file, should be what's returned by require.resolve('module')
     * @param cb (err, dependencies), where dependencies is an array of following object:
     *          {
     *              "require"   : require_name,
     *              "mpath"     : path to module,
     *              "version"   : version of module in package.json
     *          }
     *          * the first element in dependencies point to the module containing parameter file
     */
    externDependModules: function(file, cb) {
        bna.resolve(file, function(err, detail) {
            if (err) return cb(err);
            detail = bna._collapsePackages(detail);

            var ret = [detail];   // array of dependent modules to copy, [0] is the root module

            // find all depended modules not in root's path
            function isPathContained(path) {
                for (var i=0; i<ret.length; i++) {
                    if (path.indexOf(ret[i].mpath) == 0)
                        return true;
                }
                return false;
            };
            var memory = {};    // handle circular reference
            function walk(detail) {
                memory[detail.mpath] = true;
                if (!detail.isSysModule() && !isPathContained(detail.mpath)) {
                    ret.push(detail);
                }
                if (detail.deps) detail.deps.forEach(function(dep) {
                    if (!memory[dep.mpath]) walk(dep);
                });
            }
            walk(detail);

            ret = _(ret).chain().map(function(detail) { // extract wanted values
                return {
                    'require'   : detail.require,
                    'mpath'     : detail.mpath,
                    'version'   : detail.package ? detail.package.version : null
                }
            }).unique(function(detail) {    // remove duplicates
                return detail.mpath;
            }).value();
            cb(err, ret);
        })
    },

    // npmDependencies/externDependModules on dir: basically recursively scan a dir for all .js file and find their
    // merged dependencies.  This is useful when you want to calculate all dependency for all files reside in a module
    // dir and some of these .js files are not required by the main module .js file
    dir : {
        // scan dir according npm's ignore rules, by using fstream-npm
        _scanDir : function(dir, iteratorCb, doneCb) {
            async.waterfall([
                function(cb) {
                    files = [];
                    require("fstream-npm")({ path: dir })
                    .on("child", function (c) {
                        files.push(c._path);
                    })
                    .on('close', function() {
                        cb(null, files);
                    });
                },
                function(files, cb) {
                    //files = _(files).map(function(f) { return path.join(dir, f)});
                    async.each(files, function(file, cb) {
                        fs.stat(file, function(err, stat) {
                            if (stat.isDirectory() && path.basename(file)!='node_modules') {
                                iteratorCb(file, true, cb);
                            } else if (path.extname(file) == ".js") {
                                iteratorCb(file, false, cb);
                            } else cb();
                        });
                    },
                    cb);  // async.each complete
                }
            ], doneCb); // waterfall done
        },
        npmDependencies : function(dir, cb) {
            var alldeps = {};
            bna.dir._scanDir(dir,
                function(file, isDir, cb) {
                    var f = isDir ? bna.dir.npmDependencies : bna.npmDependencies;
                    f(file, function(err, deps) {
                        _(alldeps).extend(deps);
                        cb(err);
                    })
                },
                function(err) {
                    var detail = bna.identify(dir);
                    delete alldeps[detail.require];
                    cb(err, alldeps);
                }
            )
        },
        externDependModules: function(dir, cb) {
            var alldeps = [];
            bna.dir._scanDir(dir,
                function(file, isDir, cb) {
                    var f = isDir ? bna.dir.externDependModules : bna.externDependModules;
                    f(file, function(err, deps) {
                        _(alldeps).append(deps);
                        cb(err);
                    })
                },
                function(err) {
                    var deps = _(alldeps).chain()
                        .unique(function(d) {
                            return d.mpath
                        })
                        .filter(function(d) {
                            return d.mpath.indexOf(dir) !=0 ;
                        })
                        .value();
                    // keep the first which points to param, cb expects it, see comments above
                    deps = _([alldeps[0]]).append(deps);
                    cb(err, deps);
                }
            )
        }
    },
    /**
     * Make extern dependencies local by copying them to local node_modules folder
     * @param mpath     path to a dir or file (the file must be main entry point of module, i.e. returned by require.resolve
     * @param progressCb (msg),  copy in progress callback, if you want to print status
     * @param doneCb(err) completion callback
     *
     */
    copyExternDependModules : function(mpath, progressCb, doneCb) {
        var wrench = require("wrench");
        fs.stat(mpath, function(err, stat) {
            if (err) return cb(err);
            var f;
            f = stat.isDirectory() ? bna.dir.externDependModules : bna.externDependModules;
            f(mpath, function(err, dependencies){
                var targetPath = path.join(dependencies[0].mpath, "node_modules");
                if (!fs.existsSync(targetPath))
                    wrench.mkdirSyncRecursive(targetPath);
                async.eachSeries(
                    dependencies.slice(1),
                    function(d, cb) {
                        var targetModulePath = path.join(targetPath, path.basename(d.mpath));

                        progressCb(_("Copying '%s': %s => %s").format(
                            d.require,
                            path.relative(process.cwd(), d.mpath),
                            path.relative(process.cwd(), targetModulePath)));
                        if (!fs.existsSync(targetModulePath)) fs.mkdirSync(targetModulePath);
                        wrench.copyDirRecursive(d.mpath, targetModulePath, cb);
                    },
                    doneCb
                );
            });
        });
    },
    /**
     * Merge the module dependency calculated by bna.npmDependencies or bna.dir.npmDependencies into the package.json
     * of main module
     *
     * @param mpath     path to a dir or file (the file must be main entry point of module, i.e. returned by require.resolve
     * @param cb(err,)
     */
    writePackageJson : function(mpath, cb) {
        var semver = require("semver");
        fs.stat(mpath, function(err, stat) {
            if (err) return cb(err);
            var f;
            f = stat.isDirectory() ? bna.dir.npmDependencies : bna.npmDependencies;
            f(mpath, function(err, deps){
                if (err) return cb(err);
                if (stat.isFile()) mpath = bna.identify(mpath).mpath;
                var pkgJsonFile = path.join(mpath, "package.json");
                var pkgJson = {};
                if (fs.existsSync(pkgJsonFile))
                    pkgJson = JSON.parse(fs.readFileSync(pkgJsonFile, "utf8"));
                var oldDep = pkgJson.dependencies || {};
                var errList = [];
                // merge into oldDep
                _(deps).each(function(version, name) {
                    if (version == null)
                        errList.push(_("%s is not versioned!").format(name));
                    else if (!(name in oldDep)) oldDep[name] = version;
                    else {  // use semver to check
                        var oldVer = oldDep[name];
                        if (!semver.satisfies(version, oldVer)) {
                            errList.push(_("%s: %s does not satisfy %s").format(name, version, oldVer));
                        }
                    }
                });
                if (errList.length> 0) cb(new Error(errList.join("\n")));
                else {
                    pkgJson.dependencies = oldDep;
                    fs.writeFile(pkgJsonFile, JSON.stringify(pkgJson, null, 2), "utf8", cb);
                }
            })
        })
    }
}

module.exports = bna;

