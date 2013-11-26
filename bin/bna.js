#!/usr/bin/env node

var optimist = require('optimist')
    .usage('Build modules and dependencies for app in current dir.\nUsage: -b -p -c')
    .boolean(['b','p','c'])
    .alias('b', 'build')
    .alias('p', 'packagejson')
    .alias('c', 'copy')
    .describe('b', 'build app, same as -p -c together')
    .describe('p', 'write module dependencies to package.json')
    .describe('c', 'copy depended external modules to local node_modules dir')
;
var argv =  optimist.argv;

var bna = require("../lib/bna");
var fs = require("fs");
var path = require("path");

if (!(argv.b || argv.p || argv.c )) {
    console.log(optimist.help());
    if (fs.existsSync(path.join(process.cwd(), "package.json"))) {
        bna.dir.npmDependencies(process.cwd(), function(err, deps) {
            if (err) console.log(err);
            else {
                console.log("Module dependencies are:")
                console.log(deps);
            }
            bna.dir.externDependModules(process.cwd(), function(err, deps) {
                if (err) console.log(err);
                else {
                    console.log("Found extern modules:")
                    console.log(deps.slice(1));
                }
            })
        })
    }
}

if (argv.p) {
    bna.writePackageJson(process.cwd(), function(err) {
        if (err) console.log(err.stack);
        else console.log("package.json dependencies updated");
    })
}
else if (argv.c) {
    bna.copyExternDependModules(process.cwd(), function(msg) {
        console.log(msg);
    },function(err) {
        if (err) console.log(err.stack);
        else console.log("copying finished");
    })
}
else if (argv.b) {
    bna.writePackageJson(process.cwd(), function(err) {
        if (err) console.log(err.stack);
        else {
            console.log("package.json dependencies updated");
            bna.copyExternDependModules(process.cwd(), function(msg) {
                console.log(msg);
            },function(err) {
                if (err) console.log(err.stack);
                else console.log("copying finished");
            })
        }
    })
}