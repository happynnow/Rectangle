//
//  SnappingManager.swift
//  Rectangle
//
//  Created by Ryan Hanson on 9/4/19.
//  Copyright © 2019 Ryan Hanson. All rights reserved.
//

import Cocoa

class SnappingManager {

    let windowCalculationFactory: WindowCalculationFactory
    let windowHistory: WindowHistory
    
    var eventMonitor: EventMonitor?
    var frontmostWindow: AccessibilityElement?
    var frontmostWindowId: Int?
    var windowMoving: Bool = false
    var initialWindowRect: CGRect?
    var currentHotSpot: SnapArea?
    
    var box: NSWindow?
    
    let screenDetection = ScreenDetection()
    
    private let gapSize = Defaults.gapSize.value
    private let marginTop = Defaults.snapEdgeMarginTop.value
    private let marginBottom = Defaults.snapEdgeMarginBottom.value
    private let marginLeft = Defaults.snapEdgeMarginLeft.value
    private let marginRight = Defaults.snapEdgeMarginRight.value
    private let ignoredSnapAreas = SnapAreaOption(rawValue: Defaults.ignoredSnapAreas.value)
    
    init(windowCalculationFactory: WindowCalculationFactory, windowHistory: WindowHistory) {
        self.windowCalculationFactory = windowCalculationFactory
        self.windowHistory = windowHistory
        
        if Defaults.windowSnapping.enabled != false {
            enableSnapping()
        }
        
        subscribeToWindowSnappingToggle()
    }
    
    private func subscribeToWindowSnappingToggle() {
        NotificationCenter.default.addObserver(self, selector: #selector(windowSnappingToggled), name: SettingsViewController.windowSnappingNotificationName, object: nil)
    }
    
    @objc func windowSnappingToggled(notification: Notification) {
        guard let enabled = notification.object as? Bool else { return }
        if enabled {
            enableSnapping()
        } else {
            disableSnapping()
        }
    }
    
    private func enableSnapping() {
        box = generateBoxWindow()
        eventMonitor = EventMonitor(mask: [.leftMouseDown, .leftMouseUp, .leftMouseDragged], handler: handle)
        eventMonitor?.start()
    }
    
    private func disableSnapping() {
        box = nil
        eventMonitor?.stop()
        eventMonitor = nil
    }
    
    func handle(event: NSEvent?) {
        
        guard let event = event else { return }
        switch event.type {
        case .leftMouseDown:
            frontmostWindow = AccessibilityElement.frontmostWindow()
            frontmostWindowId = frontmostWindow?.getIdentifier()
            initialWindowRect = frontmostWindow?.rectOfElement()
        case .leftMouseUp:
            frontmostWindow = nil
            frontmostWindowId = nil
            windowMoving = false
            initialWindowRect = nil
            if let currentHotSpot = self.currentHotSpot {
                box?.close()
                currentHotSpot.action.postSnap(screen: currentHotSpot.screen)
                self.currentHotSpot = nil
            }
        case .leftMouseDragged:
            if frontmostWindowId == nil {
                frontmostWindowId = frontmostWindow?.getIdentifier()
            }
            guard let currentRect = frontmostWindow?.rectOfElement(),
                let windowId = frontmostWindowId
            else { return }
            
            if !windowMoving {
                if currentRect.size == initialWindowRect?.size {
                    if currentRect.origin != initialWindowRect?.origin {
                        windowMoving = true

                        if Defaults.unsnapRestore.enabled != false {
                            // if window was put there by rectangle, restore size
                            if let lastRect = windowHistory.lastRectangleActions[windowId]?.rect,
                                lastRect == initialWindowRect,
                                let restoreRect = windowHistory.restoreRects[windowId] {
                                
                                frontmostWindow?.set(size: restoreRect.size)
                                windowHistory.lastRectangleActions.removeValue(forKey: windowId)
                            } else {
                                windowHistory.restoreRects[windowId] = initialWindowRect
                            }
                        }
                    }
                }
                else {
                    windowHistory.lastRectangleActions.removeValue(forKey: windowId)
                }
            }
            if windowMoving {
                if let newHotSpot = getMouseHotSpot(priorHotSpot: currentHotSpot) {
                    if newHotSpot == currentHotSpot {
                        return
                    }
                    let currentWindow = Window(id: windowId, rect: currentRect)
                    
                    if let newBoxRect = getBoxRect(hotSpot: newHotSpot, currentWindow: currentWindow) {
                        box?.setFrame(newBoxRect, display: true)
                        box?.makeKeyAndOrderFront(nil)
                    }
                    
                    currentHotSpot = newHotSpot
                } else {
                    if currentHotSpot != nil {
                        box?.close()
                        currentHotSpot = nil
                    }
                }
            }
        default:
            return
        }
    }
    
    // Make the box semi-opaque with a border and rounded corners
    private func generateBoxWindow() -> NSWindow {
        
        let initialRect = NSRect(x: 0, y: 0, width: 0, height: 0)
        let box = NSWindow(contentRect: initialRect, styleMask: .titled, backing: .buffered, defer: false)

        box.title = "Rectangle"
        box.backgroundColor = .clear
        box.isOpaque = false
        box.level = .modalPanel
        box.hasShadow = false
        box.isReleasedWhenClosed = false
  
        box.styleMask.insert(.fullSizeContentView)
        box.titleVisibility = .hidden
        box.titlebarAppearsTransparent = true
        box.collectionBehavior.insert(.transient)
        box.standardWindowButton(.closeButton)?.isHidden = true
        box.standardWindowButton(.miniaturizeButton)?.isHidden = true
        box.standardWindowButton(.zoomButton)?.isHidden = true
        box.standardWindowButton(.toolbarButton)?.isHidden = true
        
        let boxView = NSBox()
        boxView.boxType = .custom
        boxView.borderColor = .lightGray
        boxView.borderType = .lineBorder
        boxView.borderWidth = 0.5
        boxView.cornerRadius = 5
        boxView.wantsLayer = true
        boxView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        
        box.contentView = boxView
        
        return box
    }
    
    func getBoxRect(hotSpot: SnapArea, currentWindow: Window) -> CGRect? {
        if let calculation = windowCalculationFactory.calculation(for: hotSpot.action) {
            
            let rectResult = calculation.calculateRect(currentWindow, lastAction: nil, visibleFrameOfScreen: hotSpot.screen.visibleFrame, action: hotSpot.action)
            
            if gapSize > 0, hotSpot.action.gapsApplicable {
                let gapSharedEdges = rectResult.subAction?.gapSharedEdge ?? hotSpot.action.gapSharedEdge

                return GapCalculation.applyGaps(rectResult.rect, sharedEdges: gapSharedEdges, gapSize: gapSize)
            }
            
            return rectResult.rect
        }
        return nil
    }
    
    func getMouseHotSpot(priorHotSpot: SnapArea?) -> SnapArea? {
        
        for screen in NSScreen.screens {
            let frame = screen.frame
            let loc = NSEvent.mouseLocation
            
            if loc.x >= frame.minX {
                if loc.x < frame.minX + CGFloat(marginLeft) + 20 {
                    if loc.y >= frame.maxY - CGFloat(marginTop) - 20 && loc.y <= frame.maxY {
                        return SnapArea(screen: screen, action: .topLeft)
                    }
                    if loc.y >= frame.minY && loc.y <= frame.minY + CGFloat(marginBottom) + 20 {
                        return SnapArea(screen: screen, action: .bottomLeft)
                    }
                }
                
                if loc.x < frame.minX + CGFloat(marginLeft) {
                    if loc.y >= frame.minY && loc.y <= frame.minY + CGFloat(marginBottom) + 145 {
                        return SnapArea(screen: screen, action: .bottomHalf)
                    }
                    if loc.y >= frame.maxY - CGFloat(marginTop) - 145 && loc.y <= frame.maxY {
                        return SnapArea(screen: screen, action: .topHalf)
                    }
                    if loc.y >= frame.minY && loc.y <= frame.maxY {
                        return SnapArea(screen: screen, action: .leftHalf)
                    }
                }
            }
            
            if loc.x <= frame.maxX {
                if loc.x > frame.maxX - CGFloat(marginRight) - 20 {
                    if loc.y >= frame.maxY - CGFloat(marginTop) - 20 && loc.y <= frame.maxY {
                        return SnapArea(screen: screen, action: .topRight)
                    }
                    if loc.y >= frame.minY && loc.y <= frame.minY + CGFloat(marginBottom) + 20 {
                        return SnapArea(screen: screen, action: .bottomRight)
                    }
                }

                
                if loc.x > frame.maxX - CGFloat(marginRight) {
                    if loc.y >= frame.minY && loc.y <= frame.minY + CGFloat(marginBottom) + 145 {
                        return SnapArea(screen: screen, action: .bottomHalf)
                    }
                    if loc.y >= frame.maxY - CGFloat(marginTop) - 145 && loc.y <= frame.maxY {
                        return SnapArea(screen: screen, action: .topHalf)
                    }
                    if loc.y >= frame.minY && loc.y <= frame.maxY {
                        return SnapArea(screen: screen, action: .rightHalf)
                    }
                }
            }
            
            if loc.y >= frame.minY && loc.y < frame.minY + CGFloat(marginBottom) {
                let thirdWidth = floor(frame.width / 3)
                if loc.x >= frame.minX && loc.x <= frame.minX + thirdWidth {
                    return SnapArea(screen: screen, action: .firstThird)
                }
                if loc.x >= frame.minX + thirdWidth && loc.x <= frame.maxX - thirdWidth{
                    if let priorAction = priorHotSpot?.action {
                        let action: WindowAction
                        switch priorAction {
                        case .firstThird, .firstTwoThirds:
                            action = .firstTwoThirds
                        case .lastThird, .lastTwoThirds:
                            action = .lastTwoThirds
                        default: action = .centerThird
                        }
                        return SnapArea(screen: screen, action: action)
                    }
                    return SnapArea(screen: screen, action: .centerThird)
                }
                if loc.x >= frame.minX + thirdWidth && loc.x <= frame.maxX {
                    return SnapArea(screen: screen, action: .lastThird)
                }
            }
            
            if loc.y <= frame.maxY && loc.y > frame.maxY - CGFloat(marginTop) {
                if loc.x >= frame.minX && loc.x <= frame.maxX {
                    if !ignoredSnapAreas.contains(.top) {
                        return SnapArea(screen: screen, action: .maximize)
                    }
                }
            }
            
        }
        
        return nil
    }
    
}

struct SnapArea: Equatable {
    let screen: NSScreen
    let action: WindowAction
}

struct SnapAreaOption: OptionSet {
    let rawValue: Int
    
    static let top = SnapAreaOption(rawValue: 1 << 0)
    static let sides = SnapAreaOption(rawValue: 1 << 1)
    static let sideEdges = SnapAreaOption(rawValue: 1 << 2)
    static let corners = SnapAreaOption(rawValue: 1 << 3)
    static let bottom = SnapAreaOption(rawValue: 1 << 4)
    
    static let all: SnapAreaOption = [.top, .sides, .sideEdges, .corners, .bottom]
    static let none: SnapAreaOption = []
}
