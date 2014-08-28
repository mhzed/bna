# bna

Abbreviation of "build node application".  It does a few things:

* figure out npm package dependencies by scanning source code, for lazy people
* copy package dependencies to local ./node_modules folder, once dependencies are figured out
* code "fusion":  fancy word for generating a single js file by merging all of its dependencies together:
    - no it's not simple code concatenation: generated js file runs without modification
    - circular require is supported:  as long as nodejs is happy with original code, so shall generated js file
      make nodejs happy.
    - bna knows about the binary modules (.node files): it will bundle them together with generated js and
      everything should work seemlessly.
    - yes it's kind of like [browserify](http://browserify.org), but
        * the goals are different:  bna aims to transform your awesome nodejs app into a single js file, makes it
          easier to obfuscate/distribute your code.  Unlike browserify, it does not inject implementation
          of nodejs apis.  The only code it injects are the scaffolding code to make "require" work.
        * you can use bna to "fuse" browser javascript as well:  organize your code using module/require, and then
          fuse all code into a single file to be embedded in HTML.


## Installation

npm install -g bna

## Usage

In your node projects' root directory (where package.json is), from command line just type

    bna

Read the output and go from there, it's straight-forward.

## Use case

Say in your development environment you are working on multiple projects at the same time, they share the use of same
modules, so you structure your dev folder like this:

    workspace/
        node_modules/
            async/
            request/
            express/
        projects/
            node_modules/
                my_module1/
                    package.json
            proj1/
                package.json
            proj2/
                package.json

When you need some modules, you

As you are developing in projects/, you just require what's needed in your source code.  After a while, you reach a point
where:

### my_module1/ is good enough to be shared with the world (npm publish).

But you've been lazy and haven't updated dependencies in package.json, at this point you run:

    cd  ./my_module1/
    bna -p

bna scans all source code in *my_module1/*, figures out the dependency, and merge it into package.json.  If you've
already defined dependency in package.json then bna tries to *merge* by checking if detected version is compatible with
the version specified in package.json.

* To exclude files from being analyzed for dependency, use .npmignore file


### proj1/ is ready for deployment to somewhere else

But obviously proj1/ won't run without its dependent modules, so you do:

    cd .../proj1/
    bna -c

After which you will see in proj1/

    proj1/
        node_modules/
            async/
            express/
            my_module1/

Now you can just copy proj1/ folder to anywhere and it will run without dependency problems, in other words proj1/
is now completely self-contained:  no need to run "npm install" on target machine.

### proj2/ is ready for deployment to end user, and you don't really want to expose your code to the user

Do this:

    cd .../proj2/
    bna -f -o ./fused/

You will then see
    proj2/
        fused/
            index.fused.js
            ... binary modules if any

Now run your favorite JS obfuscater on fused/main.fused.js, tar ball fused/ folder and send it to user.  To
launch your program just run command:

    node fused/index.fused.js

### you have bunch of node_modules that you want to bundle together in a single file to be used in browser or another nodejs project

Say you put your browser code in a directory

    browser_lib/node_modules/
        a/
        b/
        c/

Run

    cd browser_lib
    bna --fuselib ./ -o my.browser.lib.js

You will then have file

    browser_lib/my.browser.lib.js

And the file ends with:

    if (module === undefined) module = {};
    module.exports = {
        'a':  __global_units.__require('a/index.js'),
        'b':  __global_units.__require('b/index.js'),
        'c':  __global_units.__require('c/index.js'),
    };

In browser, module.exports['a'] will give you module a.

In nodejs, require("./my.browser.lib.js")['a'] gives you module a.