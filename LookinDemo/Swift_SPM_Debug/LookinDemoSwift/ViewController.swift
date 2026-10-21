//
//  ViewController.swift
//  LookinDemoSwift
//
//  Created by likai.123 on 2022/10/10.
//

import UIKit
import SwiftUI

extension NSObject {
    @objc func lookin_shouldCaptureImageOfView(_ view: UIView) -> Bool {
        if view.tag == 1234 {
            return true
        } else {
            return true
        }
    }
    
    @objc func lookin_collapsedClassList() -> [String] {
        return ["UIDropShadowView"]
    }
    
    @objc func lookin_colorAlias() -> [String:UIColor] {
        return ["MyWhite": UIColor.init(red: 1, green: 1, blue: 1, alpha: 1)]
    }
}

class MyView: UIView {
    @objc func lookin_shouldCaptureImage() -> Bool {
        return false
    }
}

/// 用于验证 Lookin 对 SwiftUI 视图层级的支持
struct SwiftUIDemoView: View {
    @State private var isOn = true
    @State private var sliderValue = 0.3
    @State private var text = "Hello Lookin"

    var body: some View {
        VStack(spacing: 12) {
            Text("SwiftUI Demo")
                .font(.title)
            HStack {
                Image(systemName: "star.fill")
                Text("嵌套的视图")
                    .bold()
                    .padding()
            }
            Button(action: {}) {
                VStack {
                    Text("点我")
                }
            }
            .padding(8)
            Toggle("开关", isOn: $isOn)
            Slider(value: $sliderValue)
            TextField("输入框", text: $text)
            Color.red.frame(width: 60, height: 60)
            if isOn {
                Text("条件分支")
            }
        }
        .padding()
    }
}

class ViewController: UIViewController {
    private let myButton = MyView()
    
    private let textView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        self.view.layer.borderColor = UIColor.red.cgColor
        
        textView.frame = CGRect(x: 20, y: 100, width: 200, height: 200)
        view.addSubview(textView)
        
        myButton.tag = 1234
        myButton.frame = CGRect(x: 20, y: 20, width: 50, height: 50)
        view.addSubview(myButton)
        
        // 挂载一个 SwiftUI 页面，方便在 Lookin 里查看 SwiftUI 的视图层级
        let hostingController = UIHostingController(rootView: SwiftUIDemoView())
        addChild(hostingController)
        hostingController.view.frame = CGRect(x: 0, y: 320, width: view.bounds.width, height: view.bounds.height - 320)
        hostingController.view.backgroundColor = UIColor.systemBackground
        view.addSubview(hostingController.view)
        hostingController.didMove(toParent: self)
    }


}

