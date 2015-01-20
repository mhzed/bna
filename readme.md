# bna

Stands for "build node application".  It does a few things:

* figure out npm package dependencies by scanning source code, for lazy people
* copy package dependencies to local ./node_modules folder, once dependencies are figured out
* code "fusion":  fancy word for generating a single js file by merging all of its dependencies together:
    - it's not simple code concatenation, 'require' will work.
    - circular require is supported, even in browser.
    - sourcemap files will be properly fused as well. 
    - bna tries to detect the binary modules (.node files): it will copy them to where the generated js is
    - yes it's kind of like a simpler version of [browserify](http://browserify.org)
    - fuse-able code must require constant string package names, dynamic require will be ignored 
      (but spits warnings)

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

### fuse use cases

#### Create a single js file runnable


    cd .../myprogram/
    bna -f bin/myprogram.js 
    Generated myprogram.fused.js
    
    node myprogram.fused.js
    # is equivalent of
    node bin/myprogram.js
    
    # then obfuscate/minify it
    uglifyjs myprogram.fused.js -c -m > myprogram.fused.min.js
    
#### Develop for browser in coffee-script

So you are using coffee-script and require to develop javascript code to run inside browser, the
folder structure is:

    www/
      js/
        widgets/
          menu.coffee
            menu.js
            menu.js.map
          status.coffee
            status.js
            status.js.map
          dialog.coffee
            dialog.js
            dialog.js.map
        app.coffee
          app.js
          app.js.map
          
app.coffee looks like this:

    menu = require "./widgets/menu"
    status = require "./widgets/status"
    dialog = require "./widgets/dialog"
    ...
               
Run command: 

    bna -f app.js
    Generated app.fused.js
    Generated app.fused.js.map
 
Embed app.fused.js in your html:

    <script src="js/app.fused.js"></script>

The locations in "app.fused.js" will all be properly mapped to their original coffee-script locations (verified
in safari) in browser console.
 
While in development, it's convenient to add file watchers for fuse:

    bna -f app.js -w
    
When app.js or any of the dependencies change, fuse will re-run.

#### Bundle bunch of node_modules together in a single file to be used in browser or another nodejs project

So you got a folder that contains bunch of node modules

    my_lib/
      node_modules/
        a/
        b/
        c/

Run

    cd my_lib
    bna --fuselib ./node_modules/ -o my_lib.js

You will then have file

    my_lib/my_lib.js

And use it in nodejs:

    var lib = require("my_lib/my_lib.js"); 
    lib.a   // node_module a 
    lib.b   // node_module b
    lib.c   // node_module c

Or embed it in html for browser:

    <script src="my_lib/my_lib.js"></script>
    <script type="text/javascript">
    my_lib.a;             // module a
    my_lib.b;             // module b
    my_lib.c;             // module c
    </script>

In browser, the global var 'my_lib' name is taken from path.basename of fuse output file name. 

It goes without saying that if you want to use fused js file in browser, you must not require built-in node-modules.
