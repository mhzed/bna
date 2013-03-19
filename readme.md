# bna

For building a node application.  More specifically, bna intelligently figures out your app's node module depedency (to
be expected by npm in package.json) by parsing and scanning through source code AST.

## Installation

npm install bna

## Usage

From command line, just type

    bna

Read the output and go from there, it's straight-forward.

## Use case

Say in your development envrionment you are working on multiple projects at the same time, they share the use of same
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

Essentially you place "global" modules (the ones installed by npm from npm's central repository) in
*workspace/node_modules*, and your own modules in *workspace/projects/node_modules*.  As you are developing
in proj1/, proj2/, my_module1/, you just require what's needed in your source code.  After a while, you reach a point
where:

### my_module1/ is good enough to be shared with the world (npm publish).

But you've been lazy and haven't updated dependencies in package.json, at this point you run:

    cd  .../my_module1/
    bna -p

bna scans all source code in *my_module1/*, figures out the dependency, and merge it into package.json.  If you've
already defined dependency in package.json then bna tries to *merge* by checking if detected version is compatible with
the version sepcified in package.json.

* To exclude files from being analyzed for dependency, use .npmignore file

### proj1/ is ready for deployment

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
is now completely self-contained.
