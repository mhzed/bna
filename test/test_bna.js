#!/usr/bin/env nodeunit
require('source-map-support').install();
var bna  = require("../lib/bna");
var path = require("path");
var _    = require("underscore");
var fs   = require("fs");
var async = require("async");

module.exports["test npmDependencies"] = function(test) {
    bna.npmDependencies(require.resolve("./projects/p1"), function(err, deps){
        test.ifError(err);
        //console.log(deps);
        test.equal('a' in deps, true, 'depend on a');
        test.equal('b' in deps, true, 'depend on b');
        test.equal('c' in deps, true, 'depend on c');
        test.equal('d' in deps, true, 'depend on d');
        test.equal('p1_x' in deps, true, 'depend on p1_x');

        test.done();
    })
};

module.exports["test externDependModules"] = function(test) {
    bna.npmDependencies(require.resolve("./projects/p1"), function(err, _internalDeps, deps){
        test.ifError(err);
        test.equal(_(deps).find(function(d) { return d.require == 'a'}).require, 'a', 'a should be found');
        test.equal(_(deps).find(function(d) { return d.require == 'b'}).require, 'b', 'b should be found');
        test.equal(_(deps).find(function(d) { return d.require == 'c'}).require, 'c', 'c should be found');
        test.equal(_(deps).find(function(d) { return require == 'p1_x'}), undefined, 'p1_x should not be found');
        test.done();
    })
};

module.exports["test npmDependencies on dir"] = function(test) {
    bna.npmDependencies(require.resolve("./projects/p2"), function(err, deps){
        test.ifError(err);
        test.equal('a' in deps, true, 'depend on a');
        test.equal('b' in deps, false, 'not depend on b');
        test.equal('p1_x' in deps, true, 'depend on p1_x');

        bna.dir.npmDependencies(path.join(__dirname, "./projects/p2"), function(err, deps){
            test.ifError(err);
            test.equal('a' in deps, true, 'depend on a');
            test.equal('b' in deps, true, 'depend on b');
            test.equal('p1_x' in deps, true, 'depend on p1_x');
            test.done();
        })
    })
};

module.exports["test externDependModules on dir"] = function(test) {
    bna.npmDependencies(require.resolve("./projects/p2"), function(err, _internalDeps, deps){
        test.ifError(err);
        test.equal(_(deps).find(function(d) { return d.require == 'a'}).require, 'a', 'a should be found');
        test.equal(_(deps).find(function(d) { return d.require == 'b'}), undefined, 'b should not be found');
        test.equal(_(deps).find(function(d) { return d.require == 'c'}), undefined, 'c should not be found');
        test.equal(_(deps).find(function(d) { return require == 'p1_x'}), undefined, 'p1_x should not be found');

        bna.dir.npmDependencies(path.join(__dirname, "./projects/p2"), function(err, _interDeps, deps){
            test.ifError(err);
            test.equal(_(deps).find(function(d) { return d.require == 'a'}).require, 'a', 'a should be found');
            // scanning the folder
            test.equal(_(deps).find(function(d) { return d.require == 'b'}).require, 'b', 'b should be found');
            test.done();
        })
    })
};

module.exports["test writePackageJson"] = function(test) {
    var p2dir = path.join(__dirname, "./projects/p2");
    var p2pkgfile = path.join(p2dir, "package.json");
    var readp2pkgjson = function() { return JSON.parse(fs.readFileSync(p2pkgfile, "utf8")); };

    async.series([
        function(cb) {
            bna.writePackageJson(p2dir, function(err) {
                test.ifError(err);  // should succeed
                var pkgjson = readp2pkgjson();
                test.equal('a' in  pkgjson.dependencies, true, "a should be written");
                test.equal('b' in  pkgjson.dependencies, true, "b should be written");
                test.equal('p1_x' in  pkgjson.dependencies, true, "p1_x should be written");
                cb();
            });
        },
        function(cb) {
            var pkgjson = readp2pkgjson();
            pkgjson.dependencies.a = "0.0.2";   // deliberately introduce incompatible versions
            pkgjson.dependencies.b = "1.x";
            fs.writeFileSync(p2pkgfile, JSON.stringify(pkgjson, null, 2), 'utf8');
            bna.writePackageJson(p2dir, function(err) {
                test.equal(err && /a:.* 0\.0\.1 does not/.test(err.toString()), true, "a error");
                test.equal(err && /b:.* 0\.0\.1 does not/.test(err.toString()), true, "b error");
                cb();
            });
        },
        function(cb) {  // save back original package.json
            var pkgjson = readp2pkgjson();
            delete pkgjson.dependencies;
            fs.writeFileSync(p2pkgfile, JSON.stringify(pkgjson, null, 2), 'utf8');
            cb();
        }
    ], function(err) {
        test.ifError(err);
        test.done();
    })

};

module.exports["test copyExternDependModules"] = function(test) {
    var p2dir = path.join(__dirname, "./projects/p2");
    var wrench = require("wrench");
    async.series([
        function(cb) {
            bna.copyExternDependModules(p2dir, function(msg) {
                //console.log(msg);
            }, function(err) {
                cb(err);
            })
        },
        function(cb) {
            test.equal(fs.existsSync(path.join(p2dir, 'node_modules', 'a')), true, "module a is copied");
            test.equal(fs.existsSync(path.join(p2dir, 'node_modules', 'b')), true, "module b is copied");
            cb();
        }
    ], function(err) {
        if (!err) { // clean up
            wrench.rmdirSyncRecursive(path.join(p2dir, 'node_modules', 'a'));
            wrench.rmdirSyncRecursive(path.join(p2dir, 'node_modules', 'b'));
        }

        test.ifError(err);
        test.done();
    })
};

module.exports["test fuse circular"] = function(test) {

    var spath = require.resolve("./circular/main.js");
    var dpath = path.join(path.dirname(spath), "fused.js")
    var src = bna.fuse(spath)[0];
    fs.writeFileSync(dpath, src);

    var logs = require(spath);    // original
    var logs1 = require(dpath);   // fused
    fs.unlinkSync(dpath);
    // the test is to simply executed fused and non-fused versions, make sure output is exactly the same.
    test.deepEqual(logs, logs1, "same load order");
    test.done();
};

module.exports["test fuse binary components"] = function(test) {

    var spath = require.resolve("./usews.js");
    var fusedir = path.resolve(path.dirname(spath), "usews.fuse")
    bna.fuseTo(spath, fusedir);

    //console.log(src);
    test.equal(fs.existsSync(path.join(fusedir, "usews.fused.js")) , true, "fused file");
    test.equal(fs.existsSync(path.join(fusedir, "xor.node")) , true, "binary 1");
    test.equal(fs.existsSync(path.join(fusedir, "validation.node")) , true, "binary 2");
    require("wrench").rmdirSyncRecursive(fusedir);
    test.done()
};

module.exports["test conflict modules in fusing as library"] = function(test) {
    var pdir = path.resolve(__dirname, "./projects");
    var ddir = path.resolve(__dirname, "./");
    bna.fuseDirTo(pdir, ddir, { aslib: true, dstfile: "test.project.fuse.js"}, function() {
        var ms = require(path.resolve(__dirname, "test.project.fuse.js"))

        test.equal( ms['p1@0.0.1'] !== undefined, true, "p1 exists");
        test.equal( ms['p1@0.0.2'] !== undefined, true, "p1 exists");
        //fs.unlinkSync(path.join(ddir, "test.project.fuse.js"));
        test.done();

    })
};
