fs          = require("fs");
resolver    = require("resolve");
async       = require("async");
path        = require("path");
_ = require("underscore")
acorn       = require("acorn");
ast         = require("./ast");
wrench      = require("wrench");
util = require('util');
require("colors")


jsParse = (src, opt)=>
  acorn.parse(src, _.extend(opt || {}, {
    ecmaVersion : 6,
    allowImportExportEverywhere: true,
    allowHashBang: true,
    allowReturnOutsideFunction: true,
    locations : bna.locations
  }));


module.exports = bna = {
  quiet  : false,
  locations : false,    # where to ask parser to save line locations

  warn  : (msg)->
    if not bna.quiet then console.log msg.gray

  _cache : {},    # dep.path => { dep object }

  ###
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
  ###
  identify : (file) ->
    ret = {
      "path"      : file,
      isSysModule : ()-> return this.path == this.require  # if a system module like 'path' or 'fs'
    };

    # if file is a path location, then find module path containg file
    ret.mpath = if /\/|\\/.test(file) then bna.findModulePath(file) else file;
    if (ret.mpath == file)
      ret.require = path.basename(ret.mpath).replace(/\.(js|node)$/i, '');
    else
      ret.require = path.basename(ret.mpath);
      packageJsonFile = path.join(ret.mpath, "package.json");
      if (fs.existsSync(packageJsonFile))
        ret.package = JSON.parse(fs.readFileSync(packageJsonFile));
    return ret
  ,

  findModulePath : (fullpath) ->
    if (!fullpath || fullpath == "/") then return undefined;
    if (fs.existsSync(path.join(fullpath, "package.json"))) then return fullpath;
    parentpath = path.dirname(fullpath);
    packageJsonFile = path.join(parentpath, "package.json");
    if (fs.existsSync(packageJsonFile)) then return parentpath;
    else if (path.basename(parentpath) == "node_modules") then return fullpath;
    # remove identifying pure path/index.js as a module, module must contain package.json
#    else if (['index.js', 'index.node'].indexOf(path.basename(fullpath).toLowerCase()) != -1 ) then return parentpath;
    else return bna.findModulePath(parentpath);

  mainFile : (mpath)->
    fpath
    if (fs.existsSync(fpath = path.join(mpath, "package.json")))
      pkg = JSON.parse(fs.readFileSync(fpath))
      if "main" of pkg then return path.resolve(mpath, pkg.main)
    else if (fs.existsSync(fpath = path.join(mpath, "index.js")))
      return fpath
    else if (fs.existsSync(fpath = path.join(mpath, "index.node")))
      return fpath
    return null
  ###
   * async resolve all dependencies of file,
   * because nodejs supports circular require, returned data may contain circular reference, so when you recursively
   * walk the tree, make sure you handle the circular reference, see "_collapsePackages" for example.
   *
   * @param file          : path to the js file
   * @param level         : recursively resolve up to this many levels, optional, default infinite
   * @param cb(err, detail) : where obj is what's returned by identify, with addition of 'deps' member
   *                        detail.deps   :  what this file depends on, as an array of more 'identify' details
  ###
  resolve : (file, level, cb) ->
    if (_(level).isFunction())    # handle optional level param
      cb = level;
      level = -1;

    detail = bna.identify(file); # identify module details of file
    bna._cache[file] = detail; # cache result early, for circular require

    if (level == 0 || detail.isSysModule() )   # stop at level 0, or at system module (contains no path divider)
      cb(null, detail);
      return;

    # resolve dependencies
    async.waterfall [
      (cb) ->
        allrequires = bna.findRequire(file);
        if allrequires.expressions.length > 0  # complex requires are ignored, thus print warnings
          pl = (p)->path.relative(process.cwd(), p)
          for [expr,loc] in allrequires.expressions
            bna.warn "Warning: dynamic require detected at #{pl(loc.file)}:#{loc.line}"

        requires = (name for [name,loc] in allrequires.strings); # find all requires where argument is string!
        async.map(# resolve required items to actual file path
          requires,
          (require_item, cb) ->    # resolve required item from file's basedir
            resolver(require_item, { extensions: [".js", ".node", ".json"], basedir: path.dirname(path.resolve(file)) }, (err, resolved) ->
              if (err) then cb(null, null);    # suppress resolve error
              else cb(null, resolved);
            );
          ,
          (err, resolved_items) ->
            resolved_items = _.compact(resolved_items);
            cb(err, resolved_items);
        );
    ,
      (depend_files, cb) ->
        async.map(# recursively resolve
          depend_files,
          (resolved_file, cb) ->
            if (resolved_file of bna._cache)    # use cache
              cb(null, bna._cache[resolved_file]);
            else
              bna.resolve(resolved_file, level - 1, cb);
          ,
          (err, details) ->    # all resolved, insert into "deps" member of this detail
            detail.deps = details;
            cb(err, detail);
        )
    ]
    , cb  # (err, detail),  async completion
  ,

  ###
      Internal, collapse dependent files belong to same package
      parameter is not modified
  ###
  _collapsePackages : (paramDetail) ->
    memory = {}; # handle circular reference
    doCollapse = (paramDetail)->
      memory[paramDetail.mpath] = true;
      detail = _({}).extend(paramDetail);
      if (!detail.deps) then return detail;
      deps = _(detail.deps).reduce((memo, dep) ->
        if (detail.mpath == dep.mpath)     # same package!
          if (dep.deps != undefined) then memo = _(memo).concat(dep.deps);
        else memo.push(dep);
        return memo;
      , []);
      detail.deps = _(deps).chain().map((dep) ->
        if (memory[dep.mpath]) then return dep;
        else return doCollapse(dep);
      ).unique((dep)->   # remove duplicates
        return dep.mpath;
      ).value();
      return detail;
    return doCollapse(paramDetail)
  ,
  ###
   * figures out module dependencies for you,
   *  how does it work?  by finding the main file for a package, then walk through ast of the file, find all requires
   *  to determine the external&local packages in its dependencies.
   *   * external : a required external and non-system node module
   *   * local    : the module exists locally (can be resolved via require.resolve)
   *
   * @param fpath          : path of main module file, should be what's returned by require.resolve('module')
   * @param cb(err, alldpes, externdeps, main)
   *  alldeps:  all dependencies
      externdeps:  dependences taht do not resite in fpath
      main :       the main detail for fpath
  ###
  npmDependencies : (fpath, cb) ->
    bna.resolve(require.resolve(fpath), (err, detail)->
      if (err) then return cb(err);
      detail = bna._collapsePackages(detail);
      dependencies = null;
      externDeps = null;
      if (!err)
        dependencies = _(detail.deps).reduce((memo, depDetail)->
          if (depDetail.package)
            memo[depDetail.require] = depDetail.package.version;
          else if (!depDetail.isSysModule())
            memo[depDetail.require] = null;
          return memo;
        , {});
        externDeps = bna.externDeps(detail);
      cb(err, dependencies, externDeps, detail);
    )
  ,

  ###
   *  Give a module, find all its dependencies that are NOT located in its local node_module path, useful
   *  for building the final app.

   *  Internal helper called by npmDependencies.
   *
  ###
  externDeps: (detail)->
    ret = [];
    # find all depended modules not in root's path
    isPathContained = (path)->
      for e,i in ret
        if (path.indexOf(e.mpath) == 0)
          return true;
      return false;

    memory = {};    # handle circular reference
    walk = (detail)->
      memory[detail.mpath] = true;
      if (!detail.isSysModule() && !isPathContained(detail.mpath))
        ret.push(detail);
      if (detail.deps) then detail.deps.forEach((dep)->
        if (!memory[dep.mpath])then  walk(dep);
      );
    walk(detail);

    ret = _(ret).chain().map((detail)-> # extract wanted values
      return {
          'require'   : detail.require,
          'mpath'     : detail.mpath,
          'version'   : if detail.package then detail.package.version else null
      }
    ).unique((detail)->    # remove duplicates
      return detail.mpath;
    ).value();
    return ret;
  ,

  # npmDependencies/externDependModules on dir: basically recursively scan a dir for all .js file and find their
  # merged dependencies.  This is useful when you want to calculate all dependency for all files reside in a module
  # dir and some of these .js files are not required by the main module .js file
  dir : {
      # scan dir according npm's ignore rules, by using fstream-npm
      _scanDir : (dir, iteratorCb, doneCb) ->
        async.waterfall([
          (cb) ->
            files = [];
            fnpm = require("fstream-npm")
            fnpm(
              path: dir
            ).on("child",(c)->
              files.push(c._path);
            ).on('close', ()->
              cb(null, files);
            );
        ,
          (files, cb)->
            #files = _(files).map(function(f) { return path.join(dir, f)});
            async.each(files, (file, cb)->
              fs.stat(file, (err, stat)->
                if (stat.isDirectory() && path.basename(file) != 'node_modules')
                  iteratorCb(file, true, cb);
                else if (path.extname(file) == ".js")
                  iteratorCb(file, false, cb);
                else cb();
              );
            ,
                cb);  # async.each complete
        ], doneCb); # waterfall done
      ,
      npmDependencies : (dir, cb)->
        alldeps = {};
        allextdeps = [];
        bna.dir._scanDir(dir,
          (file, isDir, cb)->
            f = if isDir then bna.dir.npmDependencies else bna.npmDependencies;
            f(file, (err, deps, extdeps)->
                _(alldeps).extend(deps);
                allextdeps = _(allextdeps).concat(extdeps);
                cb(err);
            )
          ,
          (err)->
            detail = bna.identify(dir);
            delete alldeps[detail.require];

            allextdeps = _(allextdeps).chain()
            .unique((d)->return d.mpath)
            .filter((d)->return d.mpath.indexOf(dir) != 0)
            .value();

            cb(err, alldeps, allextdeps, {mpath:dir} );

        )
  }
  ,

  ###
   * Make extern dependencies local by copying them to local node_modules folder
   * @param mpath     path to a dir or file (the file must be main entry point of module, i.e. returned by require.resolve
   * @param progressCb (msg),  copy in progress callback, if you want to print status
   * @param doneCb(err) completion callback
   *
  ###
  copyExternDependModules : (mpath, progressCb, doneCb)->
    fs.stat(mpath, (err, stat)->
      if (err) then return cb(err);
      f = if stat.isDirectory() then bna.dir.npmDependencies else bna.npmDependencies;
      f(mpath, (err, alldeps, dependencies, main)->

        targetPath = path.join(main.mpath, "node_modules")
        if (!fs.existsSync(targetPath))
          wrench.mkdirSyncRecursive(targetPath);
        async.eachSeries(
          dependencies,
          (d, cb)->
            targetModulePath = path.join(targetPath, path.basename(d.mpath));
            progressCb(util.format("Copying '%s': %s => %s",
                d.require,
                path.relative(process.cwd(), d.mpath),
                path.relative(process.cwd(), targetModulePath)));
            if (!fs.existsSync(targetModulePath)) then fs.mkdirSync(targetModulePath);
            wrench.copyDirRecursive(d.mpath, targetModulePath, cb);
          ,
          doneCb
        );
      )
    );
  ,
  ###
   * Merge the module dependency calculated by bna.npmDependencies or bna.dir.npmDependencies into the package.json
   * of main module. The merge rules are:
   * 1. if not exist yet, dependency is added
   * 2. otherwise, do not modify current package.json
        a. however if detected dependency exits in current package.json, then check if versions are compatible,
   *
   * @param mpath     path to a dir or file (the file must be main entry point of module, i.e. returned by require.resolve
   * @param cb(err, [] )  [] is removed packages
  ###
  writePackageJson : (mpath, cb)->
    semver = require("semver");
    fs.stat(mpath, (err, stat)->
      if (err) then return cb(err);
      f = if stat.isDirectory() then bna.dir.npmDependencies else bna.npmDependencies;
      f(mpath, (err, deps)->
        if (err) then return cb(err);
        if (stat.isFile()) then mpath = bna.identify(mpath).mpath;
        pkgJsonFile = path.join(mpath, "package.json");
        pkgJson = {};
        if (fs.existsSync(pkgJsonFile))
          pkgJson = JSON.parse(fs.readFileSync(pkgJsonFile, "utf8"));
        oldDep = pkgJson.dependencies || {};
        newdep = {}
        errList = [];
        # merge into oldDep
        _(deps).each((version, name)->
          if (version == null)
            errList.push(util.format("%s is not versioned!",name));
          else if (!(name of oldDep))
            newdep[name] = version;
          else  # use semver to check
            oldVer = oldDep[name];
            if /:\/\//.test(oldVer) # test for url pattern
              console.log util.format("Package %s is ignored due to non-semver %s",name, oldVer);
              delete oldDep[name]
              newdep[name] = oldVer   # keep old value
            else if (!semver.satisfies(version, oldVer))
              errList.push(util.format("%s: actual version %s does not satisfy package.json's version %s",name, version, oldVer));
            else
              delete oldDep[name]
              newdep[name] = oldVer
        )
        if (errList.length > 0)
          cb(new Error(errList.join("\n")))
        else
          pkgJson.dependencies = newdep;
          fs.writeFile(pkgJsonFile, JSON.stringify(pkgJson, null, 2), "utf8", (err)->
            cb(err, _(oldDep).keys());
          );
      )
    )
  ,
  ###
    Given js sourcecode, find require, returns
    { strings: [ ['name', location], ...]
      expressions : [['expr', location], ...]
    }
    * location is only set if opt.locations is true
    opt: { locations : true/false }
  ###
  findRequire : (filepath)->
    src = fs.readFileSync(filepath).toString();

    if (typeof src != 'string') then src = String(src);

    modules = { strings : [], expressions : [] };
    # if .json, .node, then return
    if (/\.json$/i.test(filepath) or /\.node$/i.test(filepath) ) then return modules;

    try
      src_ast = jsParse(src)
    catch e
      console.log ("Ignoring #{filepath}, failed to parse due to: #{e}")
      return modules

    ast.traverse(src_ast, (node)->
      if ast.isRequire(node)
        if (!node.loc) then node.loc={file: filepath, line:'?'}
        else node.loc.file = filepath; node.loc.line = node.loc.start.line;
        if (node.arguments.length && node.arguments[0].type == 'Literal')
          modules.strings.push([node.arguments[0].value, node.loc])
        else
          modules.expressions.push([node.arguments[0], node.loc])
    )
    return modules;

  # filepath:  path to the file to fuse
  # outdir : the output dir, needed for sourcemap concat
  # moduleName: name of main module, a global var of moduleName is created (for browser), set '' to not create
  # opts: { aslib: true|false, prependCode: "var x = require('x');" }
  # return [content, binaryUnits, warnings, units]
  # content: "fused" source code
  # binaryUnits: the binary units (.node files)
  # warnings: array of warnings: requires that are not processed
  # units: array of all file units
  fuse : (filepath, outdir, moduleName, opts)->
    opts ?= {}        # aslib: true|false
    filepath = path.resolve(filepath)
    unit = bna._parseFile(filepath, {}, opts.fakeCode)

    # get all dependencies, handles circular require via cache.
    getreqs = (unit, cache)->
      if unit.fpath of cache then return cache[unit.fpath]
      cache[unit.fpath] = units = []
      deps = _(getreqs(child_unit, cache) for {node: node, unit: child_unit} in unit.requires).flatten()
      (units.push d) for d in deps
      units.push(unit)
      units

    # get all dependencies including self (filepath), deduplicated
    units = getreqs(unit,{})
    units = _(units).unique (unit)->unit.fpath
    warnings = _(unit.warnings for unit in units).flatten()

    ret = (require("./fuse")).generate({
      baseDir : outdir
      moduleName,
      units,
      asLib: opts.aslib,
      verbose : !bna.quiet
      prependCode : opts.prependCode or ''
    });
    ret.push [warnings, units]...
    ret

  generateModuleName : (fullpath) ->
    ret = path.basename(fullpath).replace(/\..*$/, '')
    if ret.toLowerCase() == "index" then ret = path.basename(path.dirname(fullpath))
    ret

  # helper to turn warnings returned by "fuse" into human readable messages
  prettyWarnings : (warnings) ->
    msgs = {
      'nonconst': 'require dynamic modules: '
      'resolve' : 'require ignored because parameter can not be resolved'
      'dynamicResolveError' : 'dynamic required module resolve error'
    }
    pl = (l)-> if l then l else ''
    pe = (e)-> if e then ', ' + e else ''
    m = (dynamicModules)-> if dynamicModules then JSON.stringify(dynamicModules) else ''
    "#{path.relative('.',node.loc.file)}:#{pl(node.loc.line)}: #{msgs[reason]}#{pe(error)} #{m(dynamicModules)}" \
      for {node, reason, error, dynamicModules} in warnings

  # fuse filepath, write output to directory dstdir, using opts
  # opts: aslib: true|false
  fuseTo : (filepath, dstdir, opts)->
    opts ?= {}
    filepath = path.resolve(filepath)

    moduleName = bna.generateModuleName(opts.dstfile or filepath)
    [content, binaryunits, sourcemap, warnings, units] = bna.fuse(filepath, dstdir, moduleName, opts)
    bna.warn(warning) for warning in bna.prettyWarnings(warnings)
    wrench.mkdirSyncRecursive(dstdir);
    dstfile = path.resolve(dstdir, opts.dstfile or (path.basename(filepath,".js") + ".fused.js"))
    smFile = dstfile + ".map"

    console.log("Generating #{path.relative('.', dstfile)}")
    fs.writeFileSync(dstfile, content);
    if sourcemap
      console.log("Generating #{path.relative('.', smFile)}")
      sourcemap.file = path.basename(dstfile)
      fs.writeFileSync(smFile, JSON.stringify(sourcemap, null, 2));
      fs.appendFileSync(dstfile, "\n//# sourceMappingURL=#{path.basename(smFile)}")

    # copy binary units
    for bunit in binaryunits
      dfile = path.resolve(dstdir, bunit.binName)
      if fs.existsSync(dfile)
        bna.warn("Skipped copying #{dfile}, already exists.")
      else
        bna.warn("Copying to #{dfile}")
        wrench.mkdirSyncRecursive(path.dirname(dfile))
        fs.createReadStream(bunit.fpath).pipe(fs.createWriteStream(dfile));
    return units

  # read  dirpath non-recursively, fuse all found js or modules into dstdir
  # opts: aslib
  fuseDirTo : (dirpath, dstdir, opts, cb)->
    fakeCode = ""
    scandir = (curdir, cb) ->
      files = [];
      fnpm = require("fstream-npm") # for .npmignore
      fnpm(
        path: curdir
      ).on("child",(c)->
        files.push(c._path);
      ).on('close', ()->
        recursePaths = []
        for name in files
          fpath = path.resolve(curdir, name)
          stat = fs.statSync( fpath )
          if (stat.isFile())
            extname = (path.extname(name).toLowerCase())
            if name.toLowerCase() == "package.json"
              pkg = JSON.parse(fs.readFileSync(fpath))
              if pkg.main
                mpath = path.resolve(path.dirname(fpath), pkg.main)
                fakeCode += "require('./#{path.relative(dirpath, mpath)}')\n"
            else if (extname == ".js" or extname == ".node")
              fakeCode += "require('./#{path.relative(dirpath, fpath)}')\n"
          else if stat.isDirectory()
            if fs.existsSync(path.resolve(fpath, "package.json")) or
            fs.existsSync(path.resolve(fpath, "index.js")) or
            fs.existsSync(path.resolve(fpath, "index.node"))
              fakeCode += "require('./#{path.relative(dirpath, fpath)}')\n"
            else
              recursePaths.push(fpath);
        async.eachSeries( recursePaths,
          (path, cb)->scandir(fpath, cb)
          ,
          cb
        )
      )

    scandir(dirpath, ()->
      if not fakeCode
        console.log("No files detected");
      else
        opts.fakeCode = fakeCode
        units = bna.fuseTo(path.resolve(dirpath, "lib.js"), dstdir, opts)
      if cb then cb(units);
    )

  # filepath: file to analyze dependency for
  # returns: [dependency, warnings]
  # dependency is an object, key: package name, val: version
  # warnings is an array of string
  fileDep : (filepath)->
    filepath = path.resolve(filepath)
    unit = bna._parseFile(filepath, {})
    getreqs = (unit, cache)->
      if unit.fpath of cache then return cache[unit.fpath]
      cache[unit.fpath] = units = []
      units = _(units).concat(
          _(getreqs(child_unit, cache) for {node: node, unit: child_unit} in unit.requires)
          .flatten() )
      units.push(unit)
      units

    # get all dependencies including self (filepath), deduplicated
    units = getreqs(unit,{})
    units = _(units).unique (unit)->unit.fpath
    warnings = _(unit.warnings for unit in units).flatten()
    ret = {}
    for u in units when u.package
      ret[u.package.name] = u.package.version
    [ret, warnings]

  # helper: parse source code, analyze require, return results in a nested tree structure
  # filepath: must be absolute path
  _parseFile : (filepath, cache, overrideContent)->
    if filepath of cache then return cache[filepath]
    isCore = not /[\\\/]/.test(filepath);
    isBinary = /\.node$/i.test(filepath)
    unit = {
      isCore  : isCore,     # built-in nodejs modules
      isBinary : isBinary,  # binary modules, ".node" extension
      fpath : filepath,
      src   : "",
      requires : [],   # array of dependencies
      warnings : [],
      # if set, then this file is the "main" file of a node module, as defined by nodejs
      package : undefined,
    }
    cache[filepath] = unit
    if isCore or isBinary then return unit
    if overrideContent then unit.src = overrideContent
    else unit.src = fs.readFileSync(filepath).toString().replace(/^#![^\n]*\n/, '') # remove shell script marker
    if path.extname(filepath).toLowerCase() == ".json" then return unit

    # determine if parameter filepath itself represents a module, if so, mark the module by setting the
    # package member
    do ->
      detail = bna.identify(filepath)

      mainfiles = [path.join(detail.mpath, "index.js"), path.join(detail.mpath, "index.node")]
      if (detail.package)
        detail.package.name = detail.require  # ensure correct package name
        if detail.package.main
          main = path.resolve(detail.mpath, detail.package.main)
          mainfiles.push(main)
          # append .js .node variations as well
          if (path.extname(main) == '') then mainfiles.push ["#{main}.js", "#{main}.node"]...
      if unit.fpath in mainfiles
        unit.package = detail.package or {name: detail.require, version: 'x'} # construct default package if no package.json

    # do first pass without parsing location info (makes parsing 3x slower), if bad require is detected,
    # then we do another pass with location info, for user-friendly warnings
    dynamic_require_detected = false
    try
      code = jsParse(unit.src)
    catch e
      console.log ("Ignoring #{filepath}, failed to parse due to: #{e}")
      return unit
    # 1st pass, traverse ast tree, resolve all const-string requires if possible
    ast.traverse(code, [ast.isRequire], (node)->
      if (!node.loc) then node.loc = {file:filepath, line:'?'}
      else node.loc.file = filepath; node.loc.line = node.loc.start.line;

      arg = node.arguments[0]
      if arg and arg.type == 'Literal'  # require a string
        modulename = arg.value

        e = undefined
        try
          fullpath = resolver.sync(modulename, {
            extensions: ['.js', '.node', '.json'],
            basedir: path.dirname(filepath)
          });
        catch e
          unit.warnings.push
            node: node,
            reason: "resolve"

        if not e
          runit = bna._parseFile(fullpath, cache)
          unit.requires.push
            node: node,   # node.arguments[0].value is the require name
            unit: runit
      else
        dynamic_require_detected = true
        unit.warnings.push
          node: node,
          reason: "nonconst"

    )

    dynamicModules = []
    # resolving dynamic require trick: evaluate js once, recored all required modules....
    if dynamic_require_detected then do=>
      dynamicModules = bna.detectDynamicRequires(unit)

      for modulename in dynamicModules
        e = undefined
        try
          fullpath = resolver.sync(modulename, {
            extensions: ['.js', '.node', '.json'],
            basedir: path.dirname(filepath)
          });
        catch e
          unit.warnings.push
            node: {loc: {file: fullpath, line: '?', arguments: [{'value': modulename}] }},
            reason: "resolve"

        if not e  # only if resolved ok
          # fake node in ast
          if (r for r in unit.requires when r.unit.fpath == fullpath).length == 0
            node = {loc: {file: fullpath, line: '?', arguments: [{'value': modulename}] }}
            runit = bna._parseFile(fullpath, cache)
            unit.requires.push {
              node
              unit: runit
            }

    return unit;
  ,

  # the trick to detect dynamicRequire, is to run the code with a spy 'require' which captures
  # there parameters....  this works in 90%+ scenarios
  # perhaps the better way is to launch an external node process, run code with spy require, and
  # capture the modules, this covers more scenarios, but is more costly...
  detectDynamicRequires : (unit)->
    dmodules = []
    src = """
    (function() {
    var exports = {}
    var module = { "exports": exports }
    var __filename = "#{unit.fpath}"
    var __dirname = "#{path.dirname(unit.fpath)}"
    var require = function(module) {
      dmodules.push(module)
      return function(){}   // require("blah").x.x  will still fail, but what can u do?!
    };
    #{unit.src}
    })()
    """
    try
      eval src
    catch e
      unit.warnings.push
        node: {loc: {file: unit.fpath, line: '?'}, arguments: [{'value':''}]},
        reason: 'dynamicResolveError'
        error : e
    ret = _.unique(dmodules)
    ret



}