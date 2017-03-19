package haxeFormatter;

import haxe.ds.ArraySort;
import haxeFormatter.Config;
import hxParser.ParseTree;
import hxParser.Printer.print;
import hxParser.StackAwareWalker;
import hxParser.WalkStack;

enum SpacingLocation {
    Before;
    After;
}

class Processor extends StackAwareWalker {
    var config:Config;
    var prevToken:Token;
    var indentLevel:Int = 0;
    var inNoBlockExpr:Bool = false;

    public function new(config:Config) {
        this.config = config;
    }

    override function walkFile_decls(elems:Array<Decl>, stack:WalkStack) {
        super.walkFile_decls(elems, stack);
        if (config.imports.sort)
            sortImports(elems);
    }

    override function walkToken(token:Token, stack:WalkStack) {
        super.walkToken(token, stack);

        var parenInner = config.padding.parenInner.toTwoSidedPadding();
        switch (token.text) {
            case '(':
                token.trailingTrivia = padSpace(parenInner, After, token.trailingTrivia);
            case ')':
                prevToken.trailingTrivia = padSpace(parenInner, Before, prevToken.trailingTrivia);
            case ',':
                var comma = config.padding.comma;
                var config = comma.defaultPadding;
                switch (stack) {
                    case Edge(_, Node(ClassField_Property(_, _, _, _, _, _, _, _, _, _, _, _), _)):
                        config = comma.propertyAccess;
                    case _:
                }
                padSpaces(config, prevToken, token);
            case _:
        }

        if (config.indent.whitespace != null) reindent(token, stack);

        prevToken = token;
    }

    function reindent(token:Token, stack:WalkStack) {
        inline function isSwitchEdge(edge:String):Bool
            return stack.match(Edge(edge, Node(Expr_ESwitch(_,_,_,_,_), _)));

        function indentNoBlockExpr(expr:Expr) {
            if (!expr.match(EBlock(_,_,_))) {
                inNoBlockExpr = true;
                indentLevel++;
            }
        }

        function dedentNoBlockExpr() {
            if (inNoBlockExpr) {
                inNoBlockExpr = false;
                indentLevel--;
            }
        }

        switch (token.text) {
            case '{':
                reindentToken(token);
                indentLevel++;
                if (!config.indent.indentSwitches && isSwitchEdge("braceOpen")) indentLevel--;
            case '}':
                if (config.indent.indentSwitches && isSwitchEdge("braceClose")) indentLevel--;
                indentLevel--;
                reindentToken(token);
            case ')':
                switch (stack) {
                    case Edge("parenClose", Node(kind, _)):
                        switch (kind) {
                            case Expr_EIf(_,_,_,_,exprBody,_),
                                Expr_EFor(_,_,_,_,exprBody),
                                Expr_EWhile(_,_,_,_,exprBody):
                                indentNoBlockExpr(exprBody);
                            case Catch(node):
                                indentNoBlockExpr(node.expr);
                            case _:
                        }
                    case _:
                }
                reindentToken(token);
            case ';':
                dedentNoBlockExpr();
                reindentToken(token);
            case 'else':
                dedentNoBlockExpr();
                switch (stack) {
                    case Edge("elseKeyword", Node(ExprElse({ elseKeyword:_, expr:expr }), _)):
                        reindentToken(token);
                        indentNoBlockExpr(expr);
                    case _:
                        reindentToken(token);
                }
            case 'try':
                switch (stack) {
                    case Edge("tryKeyword", Node(Expr_ETry(_,exprBody,_), _)):
                        reindentToken(token);
                        indentNoBlockExpr(exprBody);
                    case _:
                        reindentToken(token);
                }
            case 'catch' | 'while':
                dedentNoBlockExpr();
                reindentToken(token);
            case 'do':
                switch (stack) {
                    case Edge("doKeyword", Node(Expr_EDo(_,exprBody,_), _)):
                        reindentToken(token);
                        indentNoBlockExpr(exprBody);
                    case _:
                        reindentToken(token);
                }
            case 'function':
                switch (stack) {
                    case Edge("functionKeyword", Node(kind, _)):
                        switch (kind) {
                            case ClassField_Function(_,_,_,_,_,_,_,_,_,expr):
                                reindentToken(token);
                                switch (expr) {
                                    case Expr(expr, _):
                                        reindentToken(token);
                                        indentNoBlockExpr(expr);
                                    case _:
                                        reindentToken(token);
                                }
                            case Expr_EFunction(_,fun):
                                reindentToken(token);
                                indentNoBlockExpr(fun.expr);
                            case _:
                                reindentToken(token);
                        }
                    case _:
                        reindentToken(token);
                }
            case _:
                switch (stack) {
                    case Edge("caseKeyword", Node(Case_Case(_,_,_,_,_), Element(index, _))):
                        if (index > 0) indentLevel--;
                        reindentToken(token);
                        indentLevel++;
                    case _:
                        reindentToken(token);
                }
        }
    }

    function reindentToken(token:Token) {
        if (prevToken == null) return;

        var prevLastTrivia = prevToken.trailingTrivia[prevToken.trailingTrivia.length - 1];
        if (prevLastTrivia == null || !prevLastTrivia.text.isNewline()) return;

        var indent = config.indent.whitespace.times(indentLevel);
        var lastTrivia = token.leadingTrivia[token.leadingTrivia.length - 1];
        if (lastTrivia != null && lastTrivia.text.isTabOrSpace())
            lastTrivia.text = indent;
        else
            token.leadingTrivia.push(new Trivia(indent));
    }

    function sortImports(decls:Array<Decl>) {
        var firstImport = getFirstImportDecl(decls);
        if (firstImport == null)
            return;

        var importToken = getImportToken(firstImport);
        var leadingTrivia = importToken.leadingTrivia;
        importToken.leadingTrivia = [];

        ArraySort.sort(decls, function(decl1, decl2) return switch [decl1, decl2] {
            case [ImportDecl(i1), ImportDecl(i2)]:
                Reflect.compare(print(i1.path), print(i2.path));

            case [UsingDecl(u1), UsingDecl(u2)]:
                Reflect.compare(print(u1.path), print(u2.path));

            case [ImportDecl(_), UsingDecl(_)]: -1;
            case [UsingDecl(_), ImportDecl(_)]: 1;

            case [ImportDecl(_), _]: -1;
            case [_, ImportDecl(_)]: 1;

            case [UsingDecl(_), _]: -1;
            case [_, UsingDecl(_)]: 1;
            case _: 0;
        });

        getImportToken(decls[0]).leadingTrivia = leadingTrivia;
    }

    function getFirstImportDecl(decls:Array<Decl>):Decl {
        for (decl in decls) {
            if (decl.match(ImportDecl(_)) || decl.match(UsingDecl(_)))
                return decl;
        }
        return null;
    }

    function getImportToken(decl:Decl):Token {
        return switch (decl) {
            case ImportDecl({importKeyword: _import}): _import;
            case UsingDecl({usingKeyword: _using}): _using;
            case _: expected("using or import");
        }
    }

    override function walkTypeHint(node:TypeHint, stack:WalkStack) {
        padSpaces(config.padding.typeHintColon, prevToken, node.colon);
        super.walkTypeHint(node, stack);
    }

    override function walkComplexType_Function(typeLeft:ComplexType, arrow:Token, typeRight:ComplexType, stack:WalkStack) {
        walkComplexType(typeLeft, stack);
        padSpaces(config.padding.functionTypeArrow, prevToken, arrow);
        super.walkComplexType_Function(typeLeft, arrow, typeRight, stack);
    }

    override function walkExpr_EBinop(exprLeft:Expr, op:Token, exprRight:Expr, stack:WalkStack) {
        walkExpr(exprLeft, stack);

        var binopConfig = config.padding.binaryOperator;
        var spacing = binopConfig.defaultPadding;
        if (binopConfig.padded.has(op.text)) spacing = Both;
        if (binopConfig.unpadded.has(op.text)) spacing = None;

        padSpaces(spacing, prevToken, op);
        super.walkExpr_EBinop(exprLeft, op, exprRight, stack);
    }

    override function walkExpr_EIf(ifKeyword:Token, parenOpen:Token, exprCond:Expr, parenClose:Token, exprThen:Expr, exprElse:Null<ExprElse>, stack:WalkStack) {
        super.walkExpr_EIf(ifKeyword, parenOpen, exprCond, parenClose, exprThen, exprElse, stack);
        padKeywordParen(ifKeyword);
    }

    override function walkExpr_EFor(forKeyword:Token, parenOpen:Token, exprIter:Expr, parenClose:Token, exprBody:Expr, stack:WalkStack) {
        super.walkExpr_EFor(forKeyword, parenOpen, exprIter, parenClose, exprBody, stack);
        padKeywordParen(forKeyword);
    }

    override function walkExpr_EWhile(whileKeyword:Token, parenOpen:Token, exprCond:Expr, parenClose:Token, exprBody:Expr, stack:WalkStack) {
        super.walkExpr_EWhile(whileKeyword, parenOpen, exprCond, parenClose, exprBody, stack);
        padKeywordParen(whileKeyword);
    }

    override function walkExpr_ESwitch(switchKeyword:Token, expr:Expr, braceOpen:Token, cases:Array<Case>, braceClose:Token, stack:WalkStack) {
        super.walkExpr_ESwitch(switchKeyword, expr, braceOpen, cases, braceClose, stack);
        padKeywordParen(switchKeyword);
    }

    function padKeywordParen(keyword:Token) {
        keyword.trailingTrivia = padSpace(config.padding.beforeParenAfterKeyword.toTwoSidedPadding(), After, keyword.trailingTrivia);
    }

    function padSpaces(padding:TwoSidedPadding, leftToken:Token, rightToken:Token) {
        leftToken.trailingTrivia = padSpace(padding, Before, leftToken.trailingTrivia);
        rightToken.trailingTrivia = padSpace(padding, After, rightToken.trailingTrivia);
    }

    function padSpace(padding:TwoSidedPadding, location:SpacingLocation, trivia:Array<Trivia>):Array<Trivia> {
        if (trivia == null)
            trivia = [];

        if (trivia.length > 0 && trivia[0].text.isNewline())
            return trivia;

        if (trivia.length > 0 && trivia[0].text.isWhitespace())
            trivia[0].text = getPadding(padding, location, trivia[0].text);
        else
            trivia.insert(0, new Trivia(getPadding(padding, location, "")));

        return trivia;
    }

    function getPadding(padding:TwoSidedPadding, location:SpacingLocation, whitespace:String):String {
        return switch [padding, location] {
            case [Ignore, _]: whitespace;
            case [Both, _], [Before, Before], [After, After]: " ";
            case _: "";
        }
    }

    inline function expected(what:String) {
        return throw '$what expected';
    }
}