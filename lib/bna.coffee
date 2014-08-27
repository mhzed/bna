fs          = require("fs");
resolver    = require("resolve");
async       = require("async");
path        = require("path");
_           = require("under_score");
esprima     = require('esprima');
ast         = require("./ast");
wrench      = require("wrench");

module.exports = bna = {
  quiet  : false,

  warn  : (msg)->
    if not bna.quiet then console.log msg

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

    ret.mpath = if /\/|\\/.test(file) then bna.findModulePath(file) else file;
    if (ret.mpath == file)    # in case of node_modules/mylib.js
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
    else if (['index.js', 'index.node'].indexOf(path.basename(fullpath).toLowerCase()) != -1 ) then return parentpath;
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
          expressions = bna.findRequire(file, {loc: true}).expressions
          for [expr,loc] in expressions
            bna.warn "Warning: ignored require expression at #{loc.file}:#{loc.start.line}"

        requires = (name for [name,loc] in allrequires.strings); # find all requires where argument is string!
        async.map(# resolve required items to actual file path
          requires,
          (require_item, cb) ->    # resolve required item from file's basedir
            resolver(require_item, { extensions: [".js", ".node"], basedir: path.dirname(path.resolve(file)) }, (err, resolved) ->
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
          if (dep.deps != undefined) then _(memo).append(dep.deps);
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
   * @param cb(err, dependencies), dependencies is what npm expects in package.json
  ###
  npmDependencies : (fpath, cb) ->
    bna.resolve(require.resolve(fpath), (err, detail)->
      if (err) then return cb(err);
      detail = bna._collapsePackages(detail);
      dependencies = null;
      if (!err)
        dependencies = _(detail.deps).reduce((memo, depDetail)->
          if (depDetail.package)
            memo[depDetail.require] = depDetail.package.version;
          else if (!depDetail.isSysModule())
            memo[depDetail.require] = null;
          return memo;
        , {});
      cb(err, dependencies);
    )
  ,

  ###
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
  ###
  externDependModules: (file, cb)->
    bna.resolve(file, (err, detail)->
      if (err) then return cb(err);
      detail = bna._collapsePackages(detail);

      ret = [detail];   # array of dependent modules to copy, [0] is the root module

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
      cb(err, ret);
    )
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
        bna.dir._scanDir(dir,
          (file, isDir, cb)->
            f = if isDir then bna.dir.npmDependencies else bna.npmDependencies;
            f(file, (err, deps)->
                _(alldeps).extend(deps);
                cb(err);
            )
          ,
          (err)->
            detail = bna.identify(dir);
            delete alldeps[detail.require];
            cb(err, alldeps);

        )
      ,
      externDependModules: (dir, cb)->
        alldeps = [];
        bna.dir._scanDir(dir,
        (file, isDir, cb)->
          f = if isDir then bna.dir.externDependModules else bna.externDependModules;
          f(file, (err, deps)->
            _(alldeps).append(deps);
            cb(err);
          )
        ,
        (err)->
          deps = _(alldeps).chain()
          .unique((d)->
              return d.mpath
            )
          .filter((d)->
              return d.mpath.indexOf(dir) != 0;
            )
          .value();
          # keep the first which points to param, cb expects it, see comments above
          deps = _([alldeps[0]]).append(deps);
          cb(err, deps);
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
      f = if stat.isDirectory() then bna.dir.externDependModules else bna.externDependModules;
      f(mpath, (err, dependencies)->
        targetPath = path.join(dependencies[0].mpath, "node_modules")
        if (!fs.existsSync(targetPath))
          wrench.mkdirSyncRecursive(targetPath);
        async.eachSeries(
            dependencies.slice(1),
        (d, cb)->
          targetModulePath = path.join(targetPath, path.basename(d.mpath));

          progressCb(_("Copying '%s': %s => %s").format(
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
        a. however if detected dependency exits in current pakcage.json, then check if versions are compatible,
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
            errList.push(_("%s is not versioned!").format(name));
          else if (!(name of oldDep))
            newdep[name] = version;
          else  # use semver to che ck
            oldVer = oldDep[name];
            if (!semver.satisfies(version, oldVer))
              errList.push(_("%s: %s does not satisfy %s").format(name, version, oldVer));
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
    * location is only set if opt.loc is true
    opt: { loc : true/false }
  ###
  findRequire : (filepath, opt)->
    opt?= {}
    src = fs.readFileSync(filepath).toString();

    if (typeof src != 'string') then src = String(src);
    src = src.replace(/^#![^\n]*\n/, ''); # remove #! shell marker

    modules = { strings : [], expressions : [] };
    # fast test for 'require'
    if (src.indexOf('require') == -1 or /\.json$/i.test(filepath) ) then return modules;

    try
      ast.traverse(esprima.parse(src, opt), (node)->
        if ast.isRequire(node)
          if opt.loc
            node.loc.file = filepath
            if (node.arguments.length && node.arguments[0].type == 'Literal')
              modules.strings.push([node.arguments[0].value, node.loc])
            else
              modules.expressions.push([node.arguments[0], node.loc])
          else
            if (node.arguments.length && node.arguments[0].type == 'Literal')
              modules.strings.push([node.arguments[0].value])
            else
              modules.expressions.push([node.arguments[0]])
      )
    catch e
      throw new Error("Unable to parse #{filepath}, original error is\n#{e.stack}")
    return modules;

  # filepath:  path to the file to fuse
  # opts: { aslib: true|false }
  # return [content, binaryUnits, warnigns]
  # content: "fused" source code
  # binaryUnits: the binary units (.node files)
  # warnings: array of warnings: requires that are not processed
  fuse : (filepath, opts)->
    opts ?= {}        # aslib: true|false
    filepath = path.resolve(filepath)
    unit = bna._parseFile(filepath, {}, opts.fakeCode)

    # get all dependencies, handles circular require via cache.
    getreqs = (unit, cache)->
      if unit.fpath of cache then return cache[unit.fpath]
      cache[unit.fpath] = units = []

      _(units).append( _(getreqs(child_unit, cache) for {node: node, unit: child_unit} in unit.requires).flatten() )
      units.push(unit)
      units

    # get all dependencies including self (filepath), deduplicated
    units = _(getreqs(unit,{})).unique (unit)->unit.fpath
    warnings = _(unit.warnings for unit in units).flatten()

    ret = (require("./fuse")).generate(units, opts.aslib);
    ret.push(warnings)
    ret

  # helper to turn warnings returned by "fuse" into human readable messages
  prettyWarnings : (warnings) ->
    msgs = {
      'nonconst': 'require ignored because parameter is not a constant string'
      'resolve' : 'require ignored because parameter can not be resolved'
    }
    "#{path.relative('.',node.loc.fpath)}:#{node.loc.start.line}: #{msgs[reason]}" \
      for {node: node, reason: reason} in warnings

  # fuse filepath, write output to directory dstdir, using opts
  # opts: aslib: true|false,  verbose: true|false
  fuseTo : (filepath, dstdir, opts)->
    opts ?= {}
    filepath = path.resolve(filepath)
    [content, binaryunits, warnings] = bna.fuse(filepath, opts)
    bna.warn(warning) for warning in bna.prettyWarnings(warnings)
    wrench.mkdirSyncRecursive(dstdir);
    dstfile = path.resolve(dstdir, opts.dstfile or (path.basename(filepath,".js") + ".fused.js"))
    if opts.verbose then console.log("Generating #{path.relative('.', dstfile)}")
    fs.writeFileSync(dstfile, content);
    for bunit in binaryunits
      dfile = path.resolve(dstdir, bunit.key)
      if fs.existsSync(dfile)
        console.log("Skipped copying #{dfile}, already exists.")
      else
        if opts.verbose then console.log("Copying to #{dfile}")
        wrench.mkdirSyncRecursive(path.dirname(dfile))
        fs.createReadStream(bunit.fpath).pipe(fs.createWriteStream(dfile));

  # read  dirpath non-recursively, fuse all found js or modules into dstdir
  # opts: aslib, verbose
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
        bna.fuseTo(path.resolve(dirpath, "lib.js"), dstdir, opts)
      if cb then cb();
    )

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
      requires : [],   # array of required modules, as object {node, unit}
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
          mainfiles.push(path.resolve(detail.mpath, detail.package.main))
      if unit.fpath in mainfiles
        unit.package = detail.package or {name: detail.require, version: 'x'} # construct default package if no package.json

    # do first pass without parsing location info (makes parsing 3x slower), if bad require is detected,
    # then we do another pass with localtion info, for user-friendly warnings
    bad_require_detected = false
    try
      code = esprima.parse(unit.src, {loc: false})
    catch e
      throw new Error("While parsing #{filepath}: #{e}");

    ast.traverse(code, [ast.isRequire], (node)->
      #node.loc.fpath = filepath
      arg = node.arguments[0]
      if arg and arg.type == 'Literal'  # require a string
        modulename = arg.value
        try
          fullpath = resolver.sync(modulename, {
            extensions: ['.js', '.node'],
            basedir: path.dirname(filepath)
          });
        catch e
          bad_require_detected = true;

        if not e  # only if resolved ok
          runit = bna._parseFile(fullpath, cache)

          unit.requires.push
            node: node,   # node.arguments[0].value is the require name
            unit: runit
      else
        bad_require_detected = true
    )

    if bad_require_detected
      code = esprima.parse(unit.src, {loc: true})
      ast.traverse(code, [ast.isRequire], (node)->
        node.loc.fpath = filepath
        arg = node.arguments[0]
        if (arg and arg.type == 'Literal')
          modulename = arg.value
          try
            resolver.sync(modulename, {
              extensions: ['.js', '.node'],
              basedir: path.dirname(filepath)
            });
          catch e
            unit.warnings.push
              node: node,
              reason: "resolve"
        else
          unit.warnings.push
            node: node,
            reason: "nonconst"
      )
    return unit;
  ,


}