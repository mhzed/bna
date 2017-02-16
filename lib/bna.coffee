fs          = require("fs");
resolver    = require("resolve");
async       = require("async");
path        = require("path");
_ = require("underscore")
ast         = require("./ast");
wrench      = require("wrench");
util = require('util');
log = require("lawg");
require("colors")

acornjsx    = require("acorn-jsx");
acorn       = require("acorn");

Parser      = acorn
ParserOptions = {
  ecmaVersion : 6,
  allowImportExportEverywhere: true,
  allowHashBang: true,
  allowReturnOutsideFunction: true,
  locations : false
}

jsParse = (src)=>
  Parser.parse(src, _.extend({}, ParserOptions, {locations : bna.locations}));


module.exports = bna = {
  enableJsx : ()->
    Parser = acornjsx
    ParserOptions.plugins = {jsx:true}

  quiet  : false,
  locations : false,    # where to ask parser to save line locations

  warn  : (msg)->
    if not bna.quiet then log msg.gray

  _cache : {},    # dep.path => { dep object }

  ###
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
  ###
  identify : (file) ->
    ret = {};

    # if file is a path location, then find module path containg file
    ret.mpath = if /\/|\\/.test(file) then bna.findModulePath(file) else file;
    if (ret.mpath == file)
      ret.mname = path.basename(ret.mpath).replace(/\.(js|node)$/i, '');
    else
      ret.mname = path.basename(ret.mpath);
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
    Internal, collapse dependent files belong to same package
    assumes unit.requires is [ {node, unit} ....] when passed in (as returned by _parseFile)
    on output, unit.requires is [ unit, .... ],  the other non consequential members are stripped out
    the recursive tree data structure is preserved.
  ###
  _collapsePackages : (unit) ->
    memory = {}; # handle circular reference
    doCollapse = (unit)->
      memory[unit.mpath] = true;
      detail = _({}).extend(unit);
      if (!detail.requires) then return detail;
      # first pass, find all requires that are not in the same module
      reqs = _(detail.requires).reduce((memo, {unit}) ->
        if (detail.mpath == unit.mpath)     # same package!
          if (unit.requires != undefined) then memo = _(memo).concat(unit for {unit} in unit.requires);
        else memo.push(unit);
        return memo;
      , []);

      detail.requires = _(reqs).chain().map((unit) ->
        if (memory[unit.mpath]) then return unit;
        else return doCollapse(unit);
      ).unique((unit)->   # remove duplicates
        return unit.mpath;
      ).value();
      return detail;

    return doCollapse(unit)
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
   *  alldeps:  all dependencies, an object, value could be:
                - string,  single version
                - array of string, multiple versions
                - null, key is either a built-in module, or a full path file (not a module main file)
      externdeps:  dependences that do not reside in fpath
      main :       the main detail for fpath
      warnings :   require resolve warnings
  ###
  npmDependencies : (fpath, cb) ->
    try
      unit = bna._parseFile(null, fpath, bna._cache);

      warnings = _(unit.warnings for unit in bna._flattenRequires(unit)).flatten()

      unit = bna._collapsePackages(unit);

      #log(JSON.stringify(unit,null, "  "));
      dependencies = null;
      externDeps = null;


      dependencies = _(unit.requires).reduce((memo, unit)->
        if (unit.package)
          memo[unit.mname] = unit.package.version;
        else
          if (unit.isCore)
            memo[unit.fpath] = null;    # required an individual file that's not a main file of a npm package
          else
            memo[unit.fpath] = null;
          memo;
        return memo;
      , {});
      externDeps = bna.externDeps(unit);

      #console.log(fpath, ", ", dependencies);
      cb(null, dependencies, externDeps, unit, warnings);
    catch e
      cb(e);
  ,

  ###
   *  Give a module, find all its dependencies that are NOT located in its local node_module path, useful
   *  for building the final app.

   *  Internal helper called by npmDependencies.
   *
  ###
  externDeps: (unit)->
    ret = [];
    # find all depended modules not in root's path
    isPathContained = (path)->
      for e,i in ret
        if (path.indexOf(e.mpath) == 0)
          return true;
      return false;

    memory = {};    # handle circular reference
    walk = (unit)->
      memory[unit.mpath] = true;
      if (!unit.isCore && !isPathContained(unit.mpath))
        ret.push(unit);
      if (unit.requires) then unit.requires.forEach((unit)->
        if (!memory[unit.mpath])then  walk(unit);
      );
    walk(unit);

    ret = _(ret).chain().map((unit)-> # extract wanted values
      return {
          'require'   : unit.mname,
          'mpath'     : unit.mpath,
          'version'   : if unit.package then unit.package.version else null
      }
    ).unique((unit)->    # remove duplicates
      return unit.mpath;
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
        allwarnings = [];
        bna.dir._scanDir(dir,
          (file, isDir, cb)->
            f = if isDir then bna.dir.npmDependencies else bna.npmDependencies;
            f(file, (err, deps, extdeps, main, warnings)->
                _(alldeps).extend(deps);
                allextdeps = _(allextdeps).concat(extdeps);
                allwarnings = _(allwarnings).concat(warnings);
                cb(err);
            )
          ,
          (err)->
            detail = bna.identify(dir);
            delete alldeps[detail.mname];

            allextdeps = _(allextdeps).chain()
            .unique((d)->return d.mpath)
            .filter((d)->return d.mpath.indexOf(dir) != 0)
            .value();

            cb(err, alldeps, allextdeps, {mpath:dir},allwarnings );

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
      f(mpath, (err, __d, extDependencies, main)->

        targetPath = path.join(main.mpath, "node_modules")
        if (!fs.existsSync(targetPath))
          wrench.mkdirSyncRecursive(targetPath);
        async.eachSeries(
          extDependencies,
          (d, cb)->
            targetModulePath = path.join(targetPath, path.basename(d.mpath));
            progressCb(util.format("Copying '%s': %s => %s",
                d.mname,
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
            #errList.push(util.format("%s is not versioned!",name));
            return
          else if (!(name of oldDep))
            newdep[name] = version;
          else  # use semver to check
            oldVer = oldDep[name];
            if /:\/\//.test(oldVer) # test for url pattern
              log util.format("Package %s is ignored due to non-semver %s",name, oldVer);
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


  # get all dependencies including self, deduplicated, and flattened
  _flattenRequires : (unit)->
    getreqs = (unit, cache)->   # use cache to handle circular require
      if unit.fpath of cache then return cache[unit.fpath]
      cache[unit.fpath] = units = []
      deps = _(getreqs(child_unit, cache) for {node: node, unit: child_unit} in unit.requires).flatten()
      (units.push d) for d in deps
      units.push(unit)
      units
    units = getreqs(unit, {});            # flatten
    _(units).unique (unit)->unit.fpath    # de-dup


  # filepath:  path to the file to fuse
  # outdir : the output dir, needed for sourcemap concat
  # moduleName: name of main module, a global var of moduleName is created (for browser), set '' to not create
  # opts: { aslib: true|false, prependCode: "var x = require('x');", generateSm: true|false }
  # return [content, binaryUnits, warnings, units]
  # content: "fused" source code
  # binaryUnits: the binary units (.node files)
  # warnings: array of warnings: requires that are not processed
  # units: array of all file units
  _fuse : (filepath, outdir, moduleName, opts)->
    opts ?= {}        # aslib: true|false
    filepath = path.resolve(filepath)
    # fakeCode: internal param, used by fuseDirTo only.  When fusing a dir, need to create a fake
    # file that requires all fused modules...
    unit = bna._parseFile(null, filepath, {}, true, opts.fakeCode, opts.ignoreMods)

    if not outdir then outdir = path.dirname(filepath)
    # get all dependencies including self (filepath), deduplicated
    units = bna._flattenRequires(unit)
    warnings = _(unit.warnings for unit in units).flatten()

    ret = (require("./fuse")).generate({
      baseDir : outdir
      moduleName,
      units,
      asLib: opts.aslib,
      generateSm : opts.generateSm,
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
    pe = (e)-> if e then ', ' + e else ''
    warnings1 = ("#{path.relative('.',node.loc.file)}:#{node.loc.line}: #{msgs[reason]}#{pe(error)}" \
      for {node, reason, error} in warnings when reason != 'nonconst')
    lines = (locs)=>((l.line for l in locs).join(','))
    warnings2 = ("#{path.relative('.',locs[0].file)}:#{lines(locs)}: #{msgs[reason]}#{modules.join(',')}" \
      for {reason, locs, modules} in warnings when reason == 'nonconst')
    warnings1.concat(warnings2)

  # fuse filepath, write output to directory dstdir, using opts
  # opts: aslib: true|false, generateSm: true|false
  fuseTo : (filepath, dstdir, opts)->
    opts ?= {}
    filepath = path.resolve(filepath)

    moduleName = bna.generateModuleName(opts.dstfile or filepath)
    [content, binaryunits, sourcemap, warnings, units] = bna._fuse(filepath, dstdir, moduleName, opts)
    bna.warn(warning) for warning in bna.prettyWarnings(warnings)
    wrench.mkdirSyncRecursive(dstdir);
    dstfile = path.resolve(dstdir, opts.dstfile or (path.basename(filepath,".js") + ".fused.js"))
    smFile = dstfile + ".map"

    log("Generating #{path.relative('.', dstfile)}")
    fs.writeFileSync(dstfile, content);
    if sourcemap
      log("Generating #{path.relative('.', smFile)}")
      sourcemap.file = path.basename(dstfile)
      fs.writeFileSync(smFile, JSON.stringify(sourcemap, null, 2));
      fs.appendFileSync(dstfile, "\n//# sourceMappingURL=#{path.basename(smFile)}")

    # copy binary units
    for bunit in binaryunits
      dfile = path.resolve(dstdir, bunit.binName)
      if fs.existsSync(dfile)
        bna.warn("Skipped copying #{dfile}, already exists.")
      else
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
        log("No files detected");
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
    unit = bna._parseFile(null, filepath, {})
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

  ###
  # helper: parse source code, recursively analyze require in code, return results in a nested tree structure
  # filepath: must be absolute path
  ###
  _parseFile : (requireName, filepath, cache, ifStoreSrc, fakeCode, coreModules)->
    if filepath of cache then return cache[filepath]
    isCore = (requireName in coreModules) or not /[\\\/]/.test(filepath) ;
    isBinary = /\.node$/i.test(filepath)
    unit = {
      isCore  : isCore,     # built-in nodejs modules
      isBinary : isBinary,  # binary modules, ".node" extension
      fpath : if isCore then requireName else filepath,     # the file path
      mpath : '',           # the path of module that contains this file
      mname : '',           # the module name
      src   : "",
      requires : [],   # array of dependencies, each element is {node, unit}
                       # node is the parded ast tree node
                       # unit is another unit
      warnings : [],
      # if set, then this file is the "main" file of a node module, as defined by nodejs
      package : undefined,
    }
    cache[filepath] = unit
    if isCore or isBinary then return unit
    if path.extname(filepath).toLowerCase() == ".json"
      if ifStoreSrc then unit.src = fs.readFileSync(filepath).toString()
      return unit

    # determine if parameter filepath itself represents a module, if so, mark the module by setting the
    # package member
    do ->
      detail = bna.identify(filepath)

      unit.mname = detail.mname;
      unit.mpath = detail.mpath;
      unit._detailPackage = detail.package;
      mainfiles = [path.join(detail.mpath, "index.js"), path.join(detail.mpath, "index.node")]
      if (detail.package)
        detail.package.name = detail.mname  # ensure correct package name
        if detail.package.main
          main = path.resolve(detail.mpath, detail.package.main)
          mainfiles.push(main)
          # append .js .node variations as well
          if (path.extname(main) == '') then mainfiles.push ["#{main}.js", "#{main}.node"]...
      if unit.fpath in mainfiles
        unit.package = detail.package or {name: detail.mname, version: 'x'} # construct default package if no package.json

    # do first pass without parsing location info (makes parsing 3x slower), if bad require is detected,
    # then we do another pass with location info, for user-friendly warnings
    try
      if fakeCode then src = fakeCode
      else src = fs.readFileSync(filepath).toString().replace(/^#![^\n]*\n/, '') # remove shell script marker

      if ifStoreSrc then unit.src = src
      code = jsParse(src)
    catch e
      log ("Ignoring #{filepath}, failed to parse due to: #{e}")
      return unit
    # 1st pass, traverse ast tree, resolve all const-string requires if possible
    dynLocs = []  # store dynamic require locations
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
          runit = bna._parseFile(modulename, fullpath, cache,ifStoreSrc, null, coreModules)
          unit.requires.push
            name : modulename
            node: node,
            unit: runit
      else
        dynLocs.push(node.loc)
    )

    # resolving dynamic require trick: evaluate js once, record all required modules....
    if dynLocs.length > 0 then do=>
      dynamicModules = bna.detectDynamicRequires(unit)
      # filter out already required string modules, and nulls
      dynamicModules = (m for m in dynamicModules when m and not _(unit.requires).find((e)=>e.name==m))

      for modulename in dynamicModules
        # filter out required modules that are already parsed
        e = undefined
        fullpath = ''   # catch block needs this too
        try
          fullpath = resolver.sync(modulename, {
            extensions: ['.js', '.node', '.json'],
            basedir: path.dirname(filepath)
          });
          # only if resolved ok
          node = {loc: {file: fullpath, line: '?'} } #
          runit = bna._parseFile(modulename, fullpath, cache, ifStoreSrc, null, coreModules)
          unit.requires.push {
            name : modulename
            node
            unit: runit
          }
        catch e
          unit.warnings.push
            node: {loc: {file: filepath, line: '?'}},
            reason: "dynamicResolveError",
            error : e

      unit.warnings.push
        locs: dynLocs
        modules: dynamicModules,
        reason: "nonconst"

    return unit;
  ,

  # the trick to detect dynamicRequire, is to run the code with a spy 'require' which captures
  # there parameters....  this works in 90%+ scenarios
  detectDynamicRequires : (unit)->
    src = """
    var _sysreq = require;
    (function() {
    var dmodules = []
    var require = function(module) {
      dmodules.push(module)
      return _sysreq(module)
    };
    #{unit.src}
    module.exports = dmodules;
    })()
    """
    tmpfile = unit.fpath + ".bna.js";
    fs.writeFileSync(tmpfile, src);
    dmodules = []
    try
      _r = require    # prevent warning when fusing bna itself
      dmodules = _.unique(_r(tmpfile));
    catch e
      unit.warnings.push
        node: {loc: {file: unit.fpath, line: '?'}},
        reason: 'dynamicResolveError'
        error : e
    finally
      delete require.cache[tmpfile]
      fs.unlinkSync(tmpfile)
      return dmodules
}