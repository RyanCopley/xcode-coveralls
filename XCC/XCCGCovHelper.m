/*******************************************************************************
 * The MIT License (MIT)
 * 
 * Copyright (c) 2014 Jean-David Gadina - www-xs-labs.com
 * 
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 * 
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 * 
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 ******************************************************************************/

#import "XCCGCovHelper.h"
#import "XCCGCovFile.h"
#import "XCCArguments.h"

@interface XCCGCovHelper()

@property( atomic, readwrite, strong ) XCCArguments * arguments;
@property( atomic, readwrite, strong ) NSArray      * files;

- ( BOOL )createError: ( NSError * __autoreleasing * )error withText: ( NSString * )text;
- ( void )log: ( NSString * )message;
- ( BOOL )processFile: ( NSString * )file files: ( NSMutableArray * )files error: ( NSError * __autoreleasing * )error;
- ( NSString * )getGCovFile: ( NSString * )outText forFile: ( NSString * )file;

@end

@implementation XCCGCovHelper

- ( instancetype )initWithArguments: ( XCCArguments * )args
{
    if( ( self = [ super init ] ) )
    {
        self.arguments = args;
    }
    
    return self;
}

- ( BOOL )run: ( NSError * __autoreleasing * )error
{
    BOOL             isDir;
    NSMutableArray * files;
    NSMutableArray * gcovFiles;
    NSString       * file;
    
    if( error != NULL )
    {
        *( error ) = nil;
    }
    
    isDir = NO;
    
    if( [ [ NSFileManager defaultManager ] fileExistsAtPath: self.arguments.buildDirectory isDirectory: &isDir ] == NO )
    {
        [ self createError: error withText: [ NSString stringWithFormat: @"Build directory does not exist: %@", self.arguments.buildDirectory ] ];
        
        return NO;
    }
    
    if( isDir == NO )
    {
        [ self createError: error withText: [ NSString stringWithFormat: @"Build directory is not a directory: %@", self.arguments.buildDirectory ] ];
        
        return NO;
    }
    
    files     = [ NSMutableArray new ];
    gcovFiles = [ NSMutableArray new ];
    
    for( file in [ [ NSFileManager defaultManager ] contentsOfDirectoryAtPath: self.arguments.buildDirectory error: NULL ] )
    {
        if( [ file.pathExtension isEqualToString: @"gcda" ] )
        {
            [ files addObject: [ self.arguments.buildDirectory stringByAppendingPathComponent: file ] ];
        }
    }
    
    if( files.count == 0 )
    {
        [ self createError: error withText: [ NSString stringWithFormat: @"No .gcda files in build directory: %@", self.arguments.buildDirectory ] ];
        
        return NO;
    }
    
    for( file in files )
    {
        if( [ self processFile: file files: gcovFiles error: error ] == NO )
        {
            return NO;
        }
    }
    
    self.files = [ NSArray arrayWithArray: gcovFiles ];
    
    return YES;
}

- ( BOOL )createError: ( NSError * __autoreleasing * )error withText: ( NSString * )text
{
    if( error == NULL || text.length == 0 )
    {
        return NO;
    }
    
    *( error ) = [ NSError errorWithDomain: @"com.xs-labs.xcode-coveralls" code: 0 userInfo: @{ NSLocalizedDescriptionKey: text } ];
    
    return YES;
}

- ( void )log: ( NSString * )message
{
    if( self.arguments.verbose )
    {
        fprintf( stdout, "%s\n", message.UTF8String );
    }
}

- ( BOOL )processFile: ( NSString * )file files: ( NSMutableArray * )files error: ( NSError * __autoreleasing * )error
{
    NSTask       * task;
    NSPipe       * outPipe;
    NSPipe       * errPipe;
    NSFileHandle * fh;
    NSData       * errorData;
    NSString     * errorText;
    NSData       * outData;
    NSString     * outText;
    XCCGCovFile  * gcovFile;
    
    task    = [ NSTask new ];
    outPipe = [ NSPipe pipe ];
    errPipe = [ NSPipe pipe ];
    
    [ task setCurrentDirectoryPath: self.arguments.buildDirectory ];
    [ task setStandardOutput: outPipe ];
    [ task setStandardError: errPipe ];
    [ task setLaunchPath: ( self.arguments.gcov == nil ) ? @"/usr/bin/gcov" : self.arguments.gcov ];
    [ task setArguments: @[ file, @"-o", self.arguments.buildDirectory ] ];
    
    [ self log: [ NSString stringWithFormat: @"xcode-coveralls: Processing file: %@", file ] ];
    
    @try
    {
        [ task launch ];
        [ task waitUntilExit ];
    }
    @catch( NSException * e )
    {
        [ self createError: error withText: e.reason ];
        
        return NO;
    }
    
    fh        = [ errPipe fileHandleForReading ];
    errorData = [ fh readDataToEndOfFile ];
    errorText = [ [ NSString alloc ] initWithData: errorData encoding: NSUTF8StringEncoding ];
    
    fh      = [ outPipe fileHandleForReading ];
    outData = [ fh readDataToEndOfFile ];
    outText = [ [ NSString alloc ] initWithData: outData encoding: NSUTF8StringEncoding ];
    
    if( errorText.length > 0 )
    {
        [ self createError: error withText: [ NSString stringWithFormat: @"gcov returned an error:\n%@", errorText ] ];
        
        return NO;
    }
    
    [ self log: outText ];
    
    gcovFile = [ [ XCCGCovFile alloc ] initWithPath: [ self getGCovFile: outText forFile: file ] ];
    
    if( gcovFile != nil )
    {
        [ files addObject: file ];
    }
    
    return YES;
}

- ( NSString * )getGCovFile: ( NSString * )outText forFile: ( NSString * )file
{
    NSRegularExpression  *                 expr;
    NSError              * __autoreleasing error;
    NSArray              *                 matches;
    NSTextCheckingResult *                 result;
    NSString             *                 match;
    
    error = nil;
    expr  = [ NSRegularExpression regularExpressionWithPattern: @"creating '([^']+)'" options: ( NSRegularExpressionOptions )0 error: &error ];
    
    if( error != nil )
    {
        return nil;
    }
    
    matches = [ expr matchesInString: outText options: ( NSMatchingOptions )0 range: NSMakeRange( 0, outText.length ) ];
    
    if( matches.count != 1 )
    {
        return nil;
    }
    
    result = matches[ 0 ];
    
    if( [ result numberOfRanges ] != 2 )
    {
        return nil;
    }
    
    match = [ outText substringWithRange: [ result rangeAtIndex: 1 ] ];
    
    return [ [ file stringByDeletingLastPathComponent ] stringByAppendingPathComponent: match ];
}

@end
